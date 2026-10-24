// Animated orb: fluid aurora blobs in a glass circle with a five-bar voice glyph.
// Ported from design/logo-pro.html. Shared animation math + pixel renderer; the caller owns the timer.
#ifndef ORB_H
#define ORB_H
#include <stdbool.h>
#include <stdint.h>

#ifdef __APPLE__
#include <CoreGraphics/CoreGraphics.h>
#endif

typedef struct {
    double w[3];      // blend weights for idle / listening / transcribing, always sum to 1
    double level;     // smoothed voice level 0..1
    double blob_t;    // accumulated blob clock (speed depends on state)
    double clock;     // real-time clock for bars, ripples and the rim arc
    int target;
} OrbAnim;

void orb_init(OrbAnim *a);
// Advance the animation by dt seconds toward `target`, with raw voice level `raw` (0..1).
void orb_tick(OrbAnim *a, double dt, int target, double raw);

#ifdef __APPLE__
// Draw into `bounds`. small = menu-bar variant: thicker glyph, no bloom or ripples.
void orb_draw(const OrbAnim *a, CGContextRef ctx, CGRect bounds, bool small);
#endif

// Portable software rasterizer: renders the orb into a premultiplied BGRA (0xAARRGGBB on little-endian)
// pixel buffer of size `width` x `height` (with `stride` in pixels), centered in sub-rect (ox, oy, ow, oh).
void orb_render_bgra(const OrbAnim *a, uint32_t *pixels, int stride, int ox, int oy, int ow, int oh, bool small);

// Shared animation math, used by orb_draw (CoreGraphics), OrbLayerView (Core Animation), and orb_render_bgra (Win32).
const double *orb_blob_color(int i); // rgb 0..1
// Blob i's offset from the orb centre and its radius, for an orb of radius r.
void orb_blob(const OrbAnim *a, int i, double r, double *dx, double *dy, double *radius);
// Bar i's size, vertical offset from the centre and alpha, blending the three states.
void orb_bar(const OrbAnim *a, int i, double r, bool small, double *w, double *h, double *dy, double *alpha);
double orb_breathe(const OrbAnim *a);   // scale factor around 1
double orb_bloom_alpha(const OrbAnim *a);
// Ripple k: progress 0..1 and alpha (already scaled by state).
void orb_ripple(const OrbAnim *a, int k, double *progress, double *alpha);
#endif
