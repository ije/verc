#include "VLC.h"
#include <dlfcn.h>
#include <dispatch/dispatch.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <stdatomic.h>

// Event types from libvlc_events.h.
#define VC_EVENT_ERROR 0x10A    // libvlc_MediaPlayerEncounteredError
#define VC_EVENT_ES_ADDED 0x114 // libvlc_MediaPlayerESAdded
#define VC_EVENT_PARSED 3
#define VC_TRACK_VIDEO 1        // libvlc_track_video

// Leading fields of libvlc_media_track_t and libvlc_video_track_t from libvlc_media.h.
typedef struct {
    unsigned height, width, sarNum, sarDen, rateNum, rateDen;
    int orientation;
} VCVideoTrack;
typedef struct {
    uint32_t codec, fourcc;
    int id, type, profile, level;
    VCVideoTrack *video;
} VCMediaTrack;

#define VLC_FUNCTIONS(X) \
    X(void *, new, (int, const char *const *)) \
    X(void, release, (void *)) \
    X(const char *, get_version, (void)) \
    X(void *, media_player_new, (void *)) \
    X(void, media_player_release, (void *)) \
    X(void *, media_player_event_manager, (void *)) \
    X(int, event_attach, (void *, int, void (*)(const void *, void *), void *)) \
    X(void, event_detach, (void *, int, void (*)(const void *, void *), void *)) \
    X(void *, media_new_location, (void *, const char *)) \
    X(void, media_release, (void *)) \
    X(void *, media_event_manager, (void *)) \
    X(int, media_parse_with_options, (void *, int, int)) \
    X(void, media_parse_stop, (void *)) \
    X(int, media_get_parsed_status, (void *)) \
    X(int64_t, media_get_duration, (void *)) \
    X(char *, media_get_mrl, (void *)) \
    X(unsigned, media_tracks_get, (void *, VCMediaTrack ***)) \
    X(void, media_tracks_release, (VCMediaTrack **, unsigned)) \
    X(void *, media_subitems, (void *)) \
    X(void, media_list_lock, (void *)) \
    X(void, media_list_unlock, (void *)) \
    X(int, media_list_count, (void *)) \
    X(void *, media_list_item_at_index, (void *, int)) \
    X(void, media_list_release, (void *)) \
    X(void, media_player_set_media, (void *, void *)) \
    X(void *, media_player_get_media, (void *)) \
    X(void, media_player_set_nsobject, (void *, void *)) \
    X(int, media_player_play, (void *)) \
    X(void, media_player_stop, (void *)) \
    X(void, media_player_set_pause, (void *, int)) \
    X(int, media_player_get_state, (void *)) \
    X(int64_t, media_player_get_time, (void *)) \
    X(int64_t, media_player_get_length, (void *)) \
    X(int, media_player_is_seekable, (void *)) \
    X(void, media_player_set_time, (void *, int64_t)) \
    X(int, audio_set_volume, (void *, int)) \
    X(int, media_player_set_rate, (void *, float)) \
    X(VCTrack *, audio_get_track_description, (void *)) \
    X(VCTrack *, video_get_spu_description, (void *)) \
    X(void, track_description_list_release, (VCTrack *)) \
    X(int, audio_get_track, (void *)) \
    X(int, video_get_spu, (void *)) \
    X(int, audio_set_track, (void *, int)) \
    X(int, video_set_spu, (void *, int)) \
    X(int, media_player_add_slave, (void *, unsigned, const char *, int)) \
    X(void, video_set_crop_geometry, (void *, const char *))

struct VCEngine {
    void *library;
    void *instance;
    void *player;
    void *subtitleState;
    void (*subtitleRelease)(void *);
    void (*subtitleLayout)(void *, VCSubtitleLayout, const char *);
    atomic_bool failed, playable;
#define DECLARE(result, name, parameters) result (*name) parameters;
    VLC_FUNCTIONS(DECLARE)
#undef DECLARE
};

static void set_flag(const void *event, void *flag) {
    (void)event;
    atomic_store((atomic_bool *)flag, true);
}

static void parsed_media(const void *event, void *signal) {
    (void)event;
    dispatch_semaphore_signal(signal);
}

VCEngine *vc_create(const char *directory, char *error, int capacity) {
    VCEngine *engine = calloc(1, sizeof(*engine));
    if (!engine) return NULL;
    char path[4096];
    snprintf(path, sizeof(path), "%s/lib/libvlccore.dylib", directory);
    void *core = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    if (!core) {
        snprintf(error, capacity, "%s", dlerror());
        free(engine);
        return NULL;
    }
    snprintf(path, sizeof(path), "%s/lib/libvlc.dylib", directory);
    engine->library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!engine->library) {
        snprintf(error, capacity, "%s", dlerror());
        dlclose(core);
        free(engine);
        return NULL;
    }
#define LOAD(result, name, parameters) \
    engine->name = dlsym(engine->library, "libvlc_" #name); \
    if (!engine->name) { \
        snprintf(error, capacity, "Missing libvlc_" #name); \
        dlclose(engine->library); dlclose(core); free(engine); return NULL; \
    }
    VLC_FUNCTIONS(LOAD)
#undef LOAD
    if (strncmp(engine->get_version(), "3.", 2) != 0) {
        snprintf(error, capacity, "Verc requires libVLC 3.x.");
        dlclose(engine->library);
        dlclose(core);
        free(engine);
        return NULL;
    }
    snprintf(path, sizeof(path), "%s/plugins", directory);
    setenv("VLC_PLUGIN_PATH", path, 1);
    snprintf(path, sizeof(path), "%s/plugins/libvercsub_plugin.dylib", directory);
    void *subtitlePlugin = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    void *(*subtitleCreate)(void *) = subtitlePlugin ? dlsym(subtitlePlugin, "verc_subtitle_create") : NULL;
    engine->subtitleRelease = subtitlePlugin ? dlsym(subtitlePlugin, "verc_subtitle_release") : NULL;
    engine->subtitleLayout = subtitlePlugin ? dlsym(subtitlePlugin, "verc_subtitle_layout") : NULL;
    bool subtitlesAvailable = subtitleCreate && engine->subtitleRelease && engine->subtitleLayout;
    const char *options[] = {
        "--ignore-config", "--no-video-title-show", "--no-osd", "--no-stats",
        "--no-media-library", "--no-video-on-top", "--no-mouse-events",
        "--no-keyboard-events", "--no-snapshot-preview", "--quiet",
        "--videotoolbox", "--videotoolbox-hw-decoder-only", "--avcodec-hw=any",
        "--vout=macosx", "--aout=auhal", "--sub-track=0",
        subtitlesAvailable ? "--sub-filter=vercsub" : "--sub-filter="
    };
    engine->instance = engine->new(sizeof(options) / sizeof(options[0]), options);
    if (engine->instance) engine->player = engine->media_player_new(engine->instance);
    if (!engine->player) {
        snprintf(error, capacity, "The VLC playback engine could not start.");
        if (engine->instance) engine->release(engine->instance);
        dlclose(engine->library);
        dlclose(core);
        free(engine);
        return NULL;
    }
    // libVLC 3 reports "ended" for media that failed or had nothing to play, so record why it ended.
    void *events = engine->media_player_event_manager(engine->player);
    engine->event_attach(events, VC_EVENT_ERROR, set_flag, &engine->failed);
    engine->event_attach(events, VC_EVENT_ES_ADDED, set_flag, &engine->playable);
    if (subtitlesAvailable) engine->subtitleState = subtitleCreate(engine->player);
    return engine;
}

void vc_destroy(VCEngine *e) {
    e->media_player_stop(e->player);
    e->media_player_release(e->player);
    e->release(e->instance);
    if (e->subtitleState) e->subtitleRelease(e->subtitleState);
    // VLC plugins can retain process-wide Objective-C classes; do not unload them.
    free(e);
}

const char *vc_version(VCEngine *e) { return e->get_version(); }
void vc_drawable(VCEngine *e, void *view) { e->media_player_set_nsobject(e->player, view); }
int vc_open(VCEngine *e, const char *uri) {
    e->media_player_stop(e->player);
    atomic_store(&e->failed, false);
    atomic_store(&e->playable, false);
    void *media = e->media_new_location(e->instance, uri);
    if (!media) return -1;
    e->media_player_set_media(e->player, media);
    e->media_release(media);
    return e->media_player_play(e->player);
}
void vc_stop(VCEngine *e) { e->media_player_stop(e->player); }
void vc_pause(VCEngine *e, int paused) { e->media_player_set_pause(e->player, paused); }
int vc_state(VCEngine *e) { return e->media_player_get_state(e->player); }
int vc_failed(VCEngine *e) { return atomic_load(&e->failed) || !atomic_load(&e->playable); }
int64_t vc_time(VCEngine *e) { return e->media_player_get_time(e->player); }
int64_t vc_duration(VCEngine *e) { return e->media_player_get_length(e->player); }
static bool parse(VCEngine *e, void *media, int network) {
    bool parsed = false;
    void *events = e->media_event_manager(media);
    dispatch_semaphore_t signal = dispatch_semaphore_create(0);
    if (e->event_attach(events, VC_EVENT_PARSED, parsed_media, signal) == 0) {
        parsed = e->media_parse_with_options(media, network, 3000) == 0 &&
            dispatch_semaphore_wait(signal, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0 &&
            e->media_get_parsed_status(media) == 4;
        e->media_parse_stop(media);
        e->event_detach(events, VC_EVENT_PARSED, parsed_media, signal);
    }
    dispatch_release(signal);
    return parsed;
}
int64_t vc_read_duration(VCEngine *e, const char *uri) {
    void *media = e->media_new_location(e->instance, uri);
    if (!media) return -1;
    int64_t duration = parse(e, media, 0) ? e->media_get_duration(media) : -1;
    e->media_release(media);
    return duration;
}
// libVLC 3 plays a playlist file as empty media, so read its entries instead.
char **vc_read_playlist(VCEngine *e, const char *uri) {
    void *media = e->media_new_location(e->instance, uri);
    if (!media) return NULL;
    char **entries = NULL;
    void *list = parse(e, media, 1) ? e->media_subitems(media) : NULL;
    if (list) {
        e->media_list_lock(list);
        int count = e->media_list_count(list), used = 0;
        entries = count > 0 ? calloc(count + 1, sizeof(*entries)) : NULL;
        for (int index = 0; entries && index < count; index++) {
            void *item = e->media_list_item_at_index(list, index);
            if (!item) continue;
            char *mrl = e->media_get_mrl(item);
            if (mrl) entries[used++] = mrl;
            e->media_release(item);
        }
        e->media_list_unlock(list);
        e->media_list_release(list);
    }
    e->media_release(media);
    return entries;
}
void vc_free_playlist(char **entries) {
    for (char **entry = entries; *entry; entry++) free(*entry);
    free(entries);
}
int vc_seekable(VCEngine *e) { return e->media_player_is_seekable(e->player); }
void vc_seek(VCEngine *e, int64_t time) { e->media_player_set_time(e->player, time); }
void vc_volume(VCEngine *e, int volume) { e->audio_set_volume(e->player, volume); }
int vc_rate(VCEngine *e, float rate) { return e->media_player_set_rate(e->player, rate); }
int vc_video_size(VCEngine *e, unsigned *width, unsigned *height, unsigned *ratioWidth, unsigned *ratioHeight) {
    void *media = e->media_player_get_media(e->player);
    if (!media) return -1;
    VCMediaTrack **tracks = NULL;
    unsigned count = e->media_tracks_get(media, &tracks);
    int result = -1;
    for (unsigned index = 0; index < count && result != 0; index++) {
        VCVideoTrack *video = tracks[index]->type == VC_TRACK_VIDEO ? tracks[index]->video : NULL;
        if (!video || !video->width || !video->height) continue;
        bool square = !video->sarNum || !video->sarDen;
        uint64_t x = (uint64_t)video->width * (square ? 1 : video->sarNum);
        uint64_t y = (uint64_t)video->height * (square ? 1 : video->sarDen);
        uint64_t divisor = x, remainder = y;
        while (remainder) { uint64_t next = divisor % remainder; divisor = remainder; remainder = next; }
        // Orientations 4 to 7 transpose the picture.
        bool swap = video->orientation & 4;
        *width = swap ? video->height : video->width;
        *height = swap ? video->width : video->height;
        *ratioWidth = (unsigned)((swap ? y : x) / divisor);
        *ratioHeight = (unsigned)((swap ? x : y) / divisor);
        result = 0;
    }
    if (count) e->media_tracks_release(tracks, count);
    e->media_release(media);
    return result;
}
VCTrack *vc_tracks(VCEngine *e, int subtitles) {
    return subtitles ? e->video_get_spu_description(e->player) : e->audio_get_track_description(e->player);
}
void vc_free_tracks(VCEngine *e, VCTrack *tracks) { e->track_description_list_release(tracks); }
int vc_selected_track(VCEngine *e, int subtitles) {
    return subtitles ? e->video_get_spu(e->player) : e->audio_get_track(e->player);
}
int vc_select_track(VCEngine *e, int subtitles, int id) {
    return subtitles ? e->video_set_spu(e->player, id) : e->audio_set_track(e->player, id);
}
int vc_add_subtitle(VCEngine *e, const char *uri) { return e->media_player_add_slave(e->player, 0, uri, 1); }
void vc_crop(VCEngine *e, const char *geometry) { e->video_set_crop_geometry(e->player, geometry); }
void vc_subtitle_layout(VCEngine *e, VCSubtitleLayout layout, const char *font) {
    if (e->subtitleState) e->subtitleLayout(e->subtitleState, layout, font);
}
