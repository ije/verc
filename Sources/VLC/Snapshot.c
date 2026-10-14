#include <vlc_common.h>
#include <vlc_plugin.h>
#include <vlc_filter.h>
#include <vlc_picture.h>
#include <vlc_modules.h>

struct filter_sys_t {
    filter_t *converter;
};

static picture_t *Buffer(filter_t *converter) {
    picture_t *picture = filter_NewPicture(converter->owner.sys);
    // VLC 3.0.24 copies from row zero but omits rows below the cropped height.
    if (picture) picture->format.i_visible_height = converter->fmt_out.video.i_y_offset + converter->fmt_out.video.i_visible_height;
    return picture;
}

static picture_t *Convert(filter_t *filter, picture_t *source) {
    filter_t *converter = filter->p_sys->converter;
    picture_t *picture = converter->pf_video_filter(converter, source);
    if (picture) picture->format.i_visible_height = filter->fmt_out.video.i_visible_height;
    return picture;
}

static void Close(vlc_object_t *object) {
    filter_t *filter = (filter_t *)object;
    filter_t *converter = filter->p_sys->converter;
    if (converter->p_module) module_unneed(converter, converter->p_module);
    es_format_Clean(&converter->fmt_in);
    es_format_Clean(&converter->fmt_out);
    vlc_object_release(converter);
    free(filter->p_sys);
}

static int Open(vlc_object_t *object) {
    filter_t *filter = (filter_t *)object;
    if (!filter->fmt_out.video.i_y_offset) return VLC_EGENERIC;
    switch (filter->fmt_in.video.i_chroma) {
        case VLC_CODEC_CVPX_NV12: case VLC_CODEC_CVPX_P010: case VLC_CODEC_CVPX_I420:
        case VLC_CODEC_CVPX_UYVY: case VLC_CODEC_CVPX_BGRA: break;
        default: return VLC_EGENERIC;
    }
    switch (filter->fmt_out.video.i_chroma) {
        case VLC_CODEC_NV12: case VLC_CODEC_P010: case VLC_CODEC_I420:
        case VLC_CODEC_I420_10L: case VLC_CODEC_UYVY: case VLC_CODEC_BGRA: break;
        default: return VLC_EGENERIC;
    }
    filter->p_sys = malloc(sizeof(*filter->p_sys));
    if (!filter->p_sys) return VLC_ENOMEM;
    filter_t *converter = vlc_object_create(filter, sizeof(*converter));
    if (!converter) { free(filter->p_sys); return VLC_ENOMEM; }
    filter->p_sys->converter = converter;
    es_format_Copy(&converter->fmt_in, &filter->fmt_in);
    es_format_Copy(&converter->fmt_out, &filter->fmt_out);
    converter->owner = (filter_owner_t){ .sys = filter, .video.buffer_new = Buffer };
    converter->p_module = module_need(converter, "video converter", "cvpx", true);
    if (!converter->p_module) { Close(object); return VLC_EGENERIC; }
    filter->pf_video_filter = Convert;
    return VLC_SUCCESS;
}

vlc_module_begin()
    set_description("Cropped CoreVideo snapshot conversion")
    set_capability("video converter", 11)
    set_callbacks(Open, Close)
vlc_module_end()
