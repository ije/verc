#pragma once
#include <stdint.h>
#include "Subtitle.h"

typedef struct VCEngine VCEngine;
typedef struct VCTrack {
    int id;
    char *name;
    struct VCTrack *next;
} VCTrack;

VCEngine *vc_create(const char *directory, char *error, int capacity);
void vc_destroy(VCEngine *engine);
const char *vc_version(VCEngine *engine);
void vc_drawable(VCEngine *engine, void *view);
int vc_open(VCEngine *engine, const char *uri);
void vc_stop(VCEngine *engine);
void vc_pause(VCEngine *engine, int paused);
int vc_state(VCEngine *engine);
int vc_failed(VCEngine *engine);
int64_t vc_time(VCEngine *engine);
int64_t vc_duration(VCEngine *engine);
int64_t vc_read_duration(VCEngine *engine, const char *uri);
char **vc_read_playlist(VCEngine *engine, const char *uri);
void vc_free_playlist(char **entries);
int vc_seekable(VCEngine *engine);
void vc_seek(VCEngine *engine, int64_t milliseconds);
void vc_volume(VCEngine *engine, int volume);
int vc_rate(VCEngine *engine, float rate);
int vc_snapshot(VCEngine *engine, const char *path);
int vc_video_size(VCEngine *engine, unsigned *width, unsigned *height, unsigned *ratioWidth, unsigned *ratioHeight);
VCTrack *vc_tracks(VCEngine *engine, int subtitles);
void vc_free_tracks(VCEngine *engine, VCTrack *tracks);
int vc_selected_track(VCEngine *engine, int subtitles);
int vc_select_track(VCEngine *engine, int subtitles, int id);
int vc_add_subtitle(VCEngine *engine, const char *uri);
void vc_crop(VCEngine *engine, const char *geometry);
void vc_subtitle_layout(VCEngine *engine, VCSubtitleLayout layout, const char *font);
