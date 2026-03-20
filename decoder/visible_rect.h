#ifndef SVI_VISIBLE_RECT_H
#define SVI_VISIBLE_RECT_H

typedef struct {
    float u0;
    float v0;
    float u1;
    float v1;
    int visible_w;
    int visible_h;
    int clipped;
} svi_visible_rect;

static inline int svi_clamp_int(int value, int low, int high) {
    if (value < low) return low;
    if (value > high) return high;
    return value;
}

static inline svi_visible_rect svi_compute_visible_rect(
    int surface_w, int surface_h,
    int frame_w, int frame_h,
    int crop_left, int crop_right,
    int crop_top, int crop_bottom)
{
    svi_visible_rect rect = {
        .u0 = 0.0f, .v0 = 0.0f, .u1 = 1.0f, .v1 = 1.0f,
        .visible_w = 0, .visible_h = 0, .clipped = 0
    };

    if (surface_w <= 0 || surface_h <= 0)
        return rect;

    if (frame_w <= 0 || frame_w > surface_w) frame_w = surface_w;
    if (frame_h <= 0 || frame_h > surface_h) frame_h = surface_h;

    crop_left = crop_left < 0 ? 0 : crop_left;
    crop_right = crop_right < 0 ? 0 : crop_right;
    crop_top = crop_top < 0 ? 0 : crop_top;
    crop_bottom = crop_bottom < 0 ? 0 : crop_bottom;

    crop_left = svi_clamp_int(crop_left, 0, frame_w - 1);
    crop_top = svi_clamp_int(crop_top, 0, frame_h - 1);

    int visible_w = frame_w - crop_left - crop_right;
    int visible_h = frame_h - crop_top - crop_bottom;
    if (visible_w <= 0) visible_w = frame_w - crop_left;
    if (visible_h <= 0) visible_h = frame_h - crop_top;
    if (visible_w <= 0) visible_w = 1;
    if (visible_h <= 0) visible_h = 1;

    if (crop_left + visible_w > surface_w)
        visible_w = surface_w - crop_left;
    if (crop_top + visible_h > surface_h)
        visible_h = surface_h - crop_top;

    if (visible_w <= 0 || visible_h <= 0) {
        crop_left = 0;
        crop_top = 0;
        visible_w = surface_w;
        visible_h = surface_h;
    }

    rect.visible_w = visible_w;
    rect.visible_h = visible_h;
    rect.u0 = (float)crop_left / (float)surface_w;
    rect.v0 = (float)crop_top / (float)surface_h;
    rect.u1 = (float)(crop_left + visible_w) / (float)surface_w;
    rect.v1 = (float)(crop_top + visible_h) / (float)surface_h;
    rect.clipped = (rect.u0 > 0.0f || rect.v0 > 0.0f ||
                    rect.u1 < 1.0f || rect.v1 < 1.0f);

    return rect;
}

#endif
