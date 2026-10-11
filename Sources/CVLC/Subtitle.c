#include <vlc_common.h>
#include <vlc_plugin.h>
#include <vlc_filter.h>
#include <vlc_subpicture.h>
#include <vlc_picture.h>
#include <CoreText/CoreText.h>
#include <pthread.h>
#include <stdatomic.h>
#include <math.h>
#include "Subtitle.h"

typedef struct {
    pthread_mutex_t lock;
    atomic_uint references;
    VCSubtitleLayout layout;
} SubtitleState;

typedef struct {
    int x, y, align;
} RegionPosition;

struct subpicture_updater_sys_t {
    SubtitleState *state;
    subpicture_t *source;
    RegionPosition *positions;
    size_t count;
    double height, fontSize;
    bool text;
};

void *verc_subtitle_create(void *player) {
    SubtitleState *state = calloc(1, sizeof(*state));
    if (!state) return NULL;
    pthread_mutex_init(&state->lock, NULL);
    atomic_init(&state->references, 1);
    state->layout.bottomInset = 42;
    state->layout.fontSize = 32;
    var_Create((vlc_object_t *)player, "verc-subtitle-state", VLC_VAR_ADDRESS);
    var_SetAddress((vlc_object_t *)player, "verc-subtitle-state", state);
    return state;
}

void verc_subtitle_release(void *context) {
    SubtitleState *state = context;
    if (atomic_fetch_sub(&state->references, 1) != 1) return;
    pthread_mutex_destroy(&state->lock);
    free(state);
}

void verc_subtitle_layout(void *context, VCSubtitleLayout layout) {
    SubtitleState *state = context;
    pthread_mutex_lock(&state->lock);
    state->layout = layout;
    pthread_mutex_unlock(&state->lock);
}

static void Layout(subpicture_t *picture) {
    subpicture_updater_sys_t *sys = picture->updater.p_sys;
    SubtitleState *state = sys->state;
    pthread_mutex_lock(&state->lock);
    VCSubtitleLayout layout = state->layout;
    pthread_mutex_unlock(&state->lock);
    double width = sys->source->i_original_picture_width;
    double height = sys->source->i_original_picture_height;
    if (width <= 0 || height <= 0 || layout.width <= 0 || layout.height <= 0) return;
    double sy = layout.height / height;
    const video_format_t *format = picture->p_region ? &picture->p_region->fmt : NULL;
    double sx = format && format->i_sar_num && format->i_sar_den
        ? sy * format->i_sar_num / format->i_sar_den : layout.width / width;
    if (sys->text && sys->count == 1) {
        subpicture_region_t *region = picture->p_region;
        if (!region->fmt.i_sar_num || !region->fmt.i_sar_den) {
            region->fmt.i_sar_num = region->fmt.i_sar_den = 1;
            sx = sy;
        }
        // Absolute positioning before the first render makes subtitles jump.
        picture->b_absolute = false;
        picture->i_original_picture_width = lround(layout.width / sx);
        picture->i_original_picture_height = lround(height);
        region->i_align = SUBPICTURE_ALIGN_BOTTOM;
        region->i_x = 0;
        region->i_y = lround(layout.bottomInset / sy);
        return;
    }
    double left = INFINITY, top = INFINITY, right = -INFINITY, bottom = -INFINITY;
    size_t index = 0;
    for (subpicture_region_t *region = picture->p_region; region && index < sys->count; region = region->p_next, index++) {
        RegionPosition original = sys->positions[index];
        double w = region->fmt.i_visible_width, h = region->fmt.i_visible_height;
        if (w <= 0 || h <= 0) return;
        double x = original.x, y = original.y;
        if (!sys->source->b_absolute) {
            x = original.align & SUBPICTURE_ALIGN_LEFT ? x : original.align & SUBPICTURE_ALIGN_RIGHT ? width - w - x : (width - w) / 2;
            y = original.align & SUBPICTURE_ALIGN_TOP ? y : original.align & SUBPICTURE_ALIGN_BOTTOM ? height - h - y : (height - h) / 2;
        }
        region->i_x = lround(x);
        region->i_y = lround(y);
        left = fmin(left, x); top = fmin(top, y);
        right = fmax(right, x + w); bottom = fmax(bottom, y + h);
    }
    if (!isfinite(left)) return;
    double w = (right - left) * sx, h = (bottom - top) * sy;
    double x = fmax(0, (layout.width - w) / 2);
    double y = fmax(0, layout.height - layout.bottomInset - h);
    for (subpicture_region_t *region = picture->p_region; region; region = region->p_next) {
        region->i_x = lround(region->i_x - left + x / sx);
        region->i_y = lround(region->i_y - top + y / sy);
        region->i_align = SUBPICTURE_ALIGN_TOP | SUBPICTURE_ALIGN_LEFT;
    }
    picture->b_absolute = true;
    picture->i_original_picture_width = lround(width);
    picture->i_original_picture_height = lround(height);
}

static int Validate(subpicture_t *picture, bool srcChanged, const video_format_t *src,
                    bool dstChanged, const video_format_t *dst, vlc_tick_t time) {
    subpicture_updater_sys_t *sys = picture->updater.p_sys;
    if (!sys->source->i_original_picture_width || !sys->source->i_original_picture_height) {
        sys->source->i_original_picture_width = src->i_visible_width;
        sys->source->i_original_picture_height = src->i_visible_height;
    }
    pthread_mutex_lock(&sys->state->lock);
    VCSubtitleLayout layout = sys->state->layout;
    pthread_mutex_unlock(&sys->state->lock);
    bool refresh = sys->text && (layout.height != sys->height || layout.fontSize != sys->fontSize);
    int result = VLC_SUCCESS;
    if (sys->source->updater.pf_validate) {
        sys->source->p_region = picture->p_region;
        // A successful validator can release a lock that its updater needs.
        result = sys->source->updater.pf_validate(sys->source, srcChanged, src, dstChanged || refresh, dst, time);
        sys->source->p_region = NULL;
    } else if (sys->source->updater.pf_update && (!sys->count || refresh || srcChanged || dstChanged)) result = VLC_EGENERIC;
    if (result == VLC_SUCCESS) Layout(picture);
    return result;
}

static void Capture(subpicture_t *picture) {
    subpicture_updater_sys_t *sys = picture->updater.p_sys;
    pthread_mutex_lock(&sys->state->lock);
    VCSubtitleLayout layout = sys->state->layout;
    pthread_mutex_unlock(&sys->state->lock);
    sys->height = layout.height;
    sys->fontSize = layout.fontSize;
    size_t count = 0;
    for (subpicture_region_t *r = picture->p_region; r; r = r->p_next) count++;
    RegionPosition *positions = realloc(sys->positions, count * sizeof(*positions));
    if (!positions && count) { sys->count = 0; return; }
    sys->positions = positions;
    sys->count = count;
    size_t index = 0;
    for (subpicture_region_t *r = picture->p_region; r; r = r->p_next) {
        positions[index++] = (RegionPosition){r->i_x, r->i_y, r->i_align};
        for (text_segment_t *text = r->p_text; text; text = text->p_next) {
            sys->text = true;
            if (layout.height <= 0) continue;
            if (!text->style) text->style = text_style_Create(STYLE_NO_DEFAULTS);
            if (!text->style) continue;
            text->style->i_font_size = lround(layout.fontSize * picture->i_original_picture_height / layout.height);
            text->style->f_font_relsize = 0;
        }
    }
    Layout(picture);
}

static void Update(subpicture_t *picture, const video_format_t *src, const video_format_t *dst, vlc_tick_t time) {
    subpicture_updater_sys_t *sys = picture->updater.p_sys;
    sys->source->p_region = NULL;
    sys->source->updater.pf_update(sys->source, src, dst, time);
    picture->p_region = sys->source->p_region;
    sys->source->p_region = NULL;
    picture->i_original_picture_width = sys->source->i_original_picture_width;
    picture->i_original_picture_height = sys->source->i_original_picture_height;
    Capture(picture);
}

static void Destroy(subpicture_t *picture) {
    subpicture_updater_sys_t *sys = picture->updater.p_sys;
    subpicture_Delete(sys->source);
    verc_subtitle_release(sys->state);
    free(sys->positions);
    free(sys);
}

static subpicture_t *Filter(filter_t *filter, subpicture_t *source) {
    SubtitleState *state = (SubtitleState *)filter->p_sys;
    if (!source->b_subtitle) return source;
    subpicture_updater_sys_t *sys = calloc(1, sizeof(*sys));
    if (!sys) return source;
    subpicture_updater_t updater = {Validate, Update, Destroy, sys};
    subpicture_t *picture = subpicture_New(&updater);
    if (!picture) { free(sys); return source; }
    subpicture_private_t *private = picture->p_private;
    *picture = *source;
    picture->updater = updater;
    picture->p_private = private;
    sys->state = state;
    sys->source = source;
    source->p_region = NULL;
    atomic_fetch_add(&state->references, 1);
    if (picture->p_region) Capture(picture);
    return picture;
}

static int Open(vlc_object_t *object) {
    filter_t *filter = (filter_t *)object;
    filter->p_sys = var_InheritAddress(filter, "verc-subtitle-state");
    if (!filter->p_sys) return VLC_EGENERIC;
    filter->pf_sub_filter = Filter;
    return VLC_SUCCESS;
}

static int RenderText(filter_t *filter, subpicture_region_t *output, subpicture_region_t *input,
                      const vlc_fourcc_t *chromas) {
    if (!input || !input->p_text) return VLC_EGENERIC;
    if (chromas && *chromas) {
        while (*chromas && *chromas != VLC_CODEC_RGBA) chromas++;
        if (!*chromas) return VLC_EGENERIC;
    }
    CFMutableAttributedStringRef text = CFAttributedStringCreateMutable(NULL, 0);
    if (!text) return VLC_ENOMEM;
    CGFloat fontSize = 1;
    for (text_segment_t *segment = input->p_text; segment; segment = segment->p_next) {
        if (!segment->psz_text || !*segment->psz_text) continue;
        CFStringRef string = CFStringCreateWithCString(NULL, segment->psz_text, kCFStringEncodingUTF8);
        if (!string) continue;
        CFRange range = CFRangeMake(CFAttributedStringGetLength(text), CFStringGetLength(string));
        CFAttributedStringReplaceString(text, CFRangeMake(range.location, 0), string);
        CFRelease(string);
        const text_style_t *style = segment->style;
        CGFloat size = style && style->i_font_size > 0 ? style->i_font_size : 32;
        fontSize = fmax(fontSize, size);
        CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, size, NULL);
        CTFontSymbolicTraits traits = 0;
        if (style && (style->i_style_flags & STYLE_BOLD)) traits |= kCTFontBoldTrait;
        if (style && (style->i_style_flags & STYLE_ITALIC)) traits |= kCTFontItalicTrait;
        if (traits) {
            CTFontRef styled = CTFontCreateCopyWithSymbolicTraits(font, 0, NULL, traits, traits);
            if (styled) { CFRelease(font); font = styled; }
        }
        uint32_t rgb = style && (style->i_features & STYLE_HAS_FONT_COLOR) ? style->i_font_color : 0xFFFFFF;
        CGFloat alpha = style && (style->i_features & STYLE_HAS_FONT_ALPHA) ? style->i_font_alpha / 255.0 : 1;
        CGColorRef color = CGColorCreateGenericRGB(((rgb >> 16) & 255) / 255.0, ((rgb >> 8) & 255) / 255.0, (rgb & 255) / 255.0, alpha);
        CFAttributedStringSetAttribute(text, range, kCTFontAttributeName, font);
        CFAttributedStringSetAttribute(text, range, kCTForegroundColorAttributeName, color);
        if (style && (style->i_style_flags & STYLE_UNDERLINE)) {
            int value = kCTUnderlineStyleSingle;
            CFNumberRef underline = CFNumberCreate(NULL, kCFNumberIntType, &value);
            CFAttributedStringSetAttribute(text, range, kCTUnderlineStyleAttributeName, underline);
            CFRelease(underline);
        }
        CGColorRelease(color);
        CFRelease(font);
    }
    if (!CFAttributedStringGetLength(text)) { CFRelease(text); return VLC_EGENERIC; }
    CTTextAlignment alignment = input->i_text_align & SUBPICTURE_ALIGN_LEFT ? kCTTextAlignmentLeft
        : input->i_text_align & SUBPICTURE_ALIGN_RIGHT ? kCTTextAlignmentRight : kCTTextAlignmentCenter;
    CTParagraphStyleSetting setting = {kCTParagraphStyleSpecifierAlignment, sizeof(alignment), &alignment};
    CTParagraphStyleRef paragraph = CTParagraphStyleCreate(&setting, 1);
    CFAttributedStringSetAttribute(text, CFRangeMake(0, CFAttributedStringGetLength(text)), kCTParagraphStyleAttributeName, paragraph);
    CFRelease(paragraph);
    CTFramesetterRef framesetter = CTFramesetterCreateWithAttributedString(text);
    CFRelease(text);
    CGFloat padding = ceil(fontSize / 8);
    CGFloat maxWidth = filter->fmt_out.video.i_visible_width;
    CGFloat maxHeight = filter->fmt_out.video.i_visible_height;
    if (input->i_max_width > 0) maxWidth = fmin(maxWidth, input->i_max_width);
    if (input->i_max_height > 0) maxHeight = fmin(maxHeight, input->i_max_height);
    maxWidth = fmax(1, maxWidth - 2 * padding);
    maxHeight = fmax(1, maxHeight - 2 * padding);
    CGSize size = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRangeMake(0, 0), NULL,
                                                            CGSizeMake(maxWidth, maxHeight), NULL);
    unsigned width = ceil(fmin(maxWidth, ceil(size.width) + 1) + 2 * padding);
    unsigned height = ceil(size.height + 2 * padding);
    video_format_t format;
    video_format_Init(&format, VLC_CODEC_RGBA);
    video_format_Setup(&format, VLC_CODEC_RGBA, width, height, width, height, 1, 1);
    picture_t *picture = picture_NewFromFormat(&format);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = picture ? CGBitmapContextCreate(picture->p[0].p_pixels, width, height, 8,
        picture->p[0].i_pitch, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big) : NULL;
    CGColorSpaceRelease(space);
    if (!context) {
        if (picture) picture_Release(picture);
        CFRelease(framesetter);
        return VLC_ENOMEM;
    }
    CGContextClearRect(context, CGRectMake(0, 0, width, height));
    CGContextSetShouldSmoothFonts(context, false);
    CGColorRef shadow = CGColorCreateGenericRGB(0, 0, 0, 1);
    CGContextSetShadowWithColor(context, CGSizeMake(0, -fontSize / 32), fontSize / 16, shadow);
    CGColorRelease(shadow);
    CGPathRef path = CGPathCreateWithRect(CGRectMake(padding, padding, width - 2 * padding, height - 2 * padding), NULL);
    CTFrameRef frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, NULL);
    CTFrameDraw(frame, context);
    CFRelease(frame);
    CGPathRelease(path);
    CGContextRelease(context);
    CFRelease(framesetter);
    // Core Graphics premultiplies alpha, but VLC expects straight RGBA.
    for (unsigned y = 0; y < height; y++) {
        uint8_t *pixel = picture->p[0].p_pixels + y * picture->p[0].i_pitch;
        for (unsigned x = 0; x < width; x++, pixel += 4) {
            if (pixel[3] && pixel[3] != 255) {
                for (int c = 0; c < 3; c++) pixel[c] = __MIN(255, (pixel[c] * 255 + pixel[3] / 2) / pixel[3]);
            }
        }
    }
    output->fmt = format;
    output->p_picture = picture;
    return VLC_SUCCESS;
}

static int OpenText(vlc_object_t *object) {
    ((filter_t *)object)->pf_render = RenderText;
    return VLC_SUCCESS;
}

vlc_module_begin()
    set_shortname("Verc subtitles")
    set_description("Subtitle layout")
    set_capability("sub filter", 0)
    set_callbacks(Open, NULL)
    add_shortcut("vercsub")
    add_submodule()
    set_description("System font subtitles")
    set_capability("text renderer", 100)
    set_callbacks(OpenText, NULL)
    add_shortcut("verctext")
vlc_module_end()
