#include "CVLC.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>

#define VLC_FUNCTIONS(X) \
    X(void *, new, (int, const char *const *)) \
    X(void, release, (void *)) \
    X(const char *, get_version, (void)) \
    X(void *, media_player_new, (void *)) \
    X(void, media_player_release, (void *)) \
    X(void *, media_new_location, (void *, const char *)) \
    X(void, media_release, (void *)) \
    X(void, media_player_set_media, (void *, void *)) \
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
    X(int, video_get_size, (void *, unsigned, unsigned *, unsigned *)) \
    X(VCTrack *, audio_get_track_description, (void *)) \
    X(VCTrack *, video_get_spu_description, (void *)) \
    X(void, track_description_list_release, (VCTrack *)) \
    X(int, audio_get_track, (void *)) \
    X(int, video_get_spu, (void *)) \
    X(int, audio_set_track, (void *, int)) \
    X(int, video_set_spu, (void *, int)) \
    X(int, media_player_add_slave, (void *, unsigned, const char *, int)) \
    X(int, video_set_spu_delay, (void *, int64_t)) \
    X(void, video_set_crop_geometry, (void *, const char *))

struct VCEngine {
    void *library;
    void *instance;
    void *player;
    void *subtitleState;
    void (*subtitleRelease)(void *);
    void (*subtitleLayout)(void *, VCSubtitleLayout);
#define DECLARE(result, name, parameters) result (*name) parameters;
    VLC_FUNCTIONS(DECLARE)
#undef DECLARE
};

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
        "--vout=macosx", "--aout=auhal",
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
    void *media = e->media_new_location(e->instance, uri);
    if (!media) return -1;
    e->media_player_set_media(e->player, media);
    e->media_release(media);
    return e->media_player_play(e->player);
}
void vc_stop(VCEngine *e) { e->media_player_stop(e->player); }
void vc_pause(VCEngine *e, int paused) { e->media_player_set_pause(e->player, paused); }
int vc_state(VCEngine *e) { return e->media_player_get_state(e->player); }
int64_t vc_time(VCEngine *e) { return e->media_player_get_time(e->player); }
int64_t vc_duration(VCEngine *e) { return e->media_player_get_length(e->player); }
int vc_seekable(VCEngine *e) { return e->media_player_is_seekable(e->player); }
void vc_seek(VCEngine *e, int64_t time) { e->media_player_set_time(e->player, time); }
void vc_volume(VCEngine *e, int volume) { e->audio_set_volume(e->player, volume); }
int vc_rate(VCEngine *e, float rate) { return e->media_player_set_rate(e->player, rate); }
int vc_video_size(VCEngine *e, unsigned *width, unsigned *height) {
    return e->video_get_size(e->player, 0, width, height);
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
int vc_subtitle_delay(VCEngine *e, int64_t delay) { return e->video_set_spu_delay(e->player, delay); }
void vc_crop(VCEngine *e, const char *geometry) { e->video_set_crop_geometry(e->player, geometry); }
void vc_subtitle_layout(VCEngine *e, VCSubtitleLayout layout) {
    if (e->subtitleState) e->subtitleLayout(e->subtitleState, layout);
}
