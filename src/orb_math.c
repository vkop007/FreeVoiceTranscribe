#include "orb.h"
#include <math.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static const double kBlobColors[6][3] = {
    {0.486, 0.361, 1.0},   // violet  #7c5cff
    {0.0, 0.831, 1.0},     // cyan    #00d4ff
    {1.0, 0.361, 0.659},   // magenta #ff5ca8
    {1.0, 0.706, 0.329},   // amber   #ffb454
    {0.23, 0.29, 1.0},     // blue
    {0.62, 0.40, 1.0},     // violet 2
};

void orb_init(OrbAnim *a) {
    *a = (OrbAnim){.w = {1, 0, 0}};
}

static double approach(double dt, double tau) { return 1.0 - exp(-dt / tau); }

void orb_tick(OrbAnim *a, double dt, int target, double raw) {
    if (dt > 0.1) dt = 0.1;
    a->target = target;
    double k = approach(dt, 0.16);
    for (int i = 0; i < 3; i++) a->w[i] += ((i == target ? 1.0 : 0.0) - a->w[i]) * k;
    double want = target == 1 ? raw : 0;
    a->level += (want - a->level) * approach(dt, want > a->level ? 0.05 : 0.16);
    double speed = a->w[0] * 0.35 + a->w[1] * (1.1 + 1.3 * a->level) + a->w[2] * 0.85;
    a->blob_t += dt * speed;
    a->clock += dt;
}

const double *orb_blob_color(int i) { return kBlobColors[i]; }

void orb_blob(const OrbAnim *a, int i, double r, double *dx, double *dy, double *radius) {
    double t = a->blob_t;
    double ang = t * (0.6 + 0.17 * i) + i * 1.7;
    double orbit = r * 0.42 * (0.6 + 0.4 * sin(t * 0.5 + i));
    *dx = cos(ang) * orbit;
    *dy = sin(ang * 1.13 + i) * orbit;
    *radius = r * (0.62 + 0.5 * a->level * a->w[1] + 0.05 * sin(t * 1.3 + i * 2));
}

void orb_bar(const OrbAnim *a, int i, double r, bool small, double *w, double *h, double *dy, double *alpha) {
    static const double env[5] = {0.6, 0.85, 1.0, 0.85, 0.6};
    double bw = small ? r * 0.2 : r * 0.13;
    double clk = a->clock;
    double wi = 0, hi = 0, yi = 0, ai = 0;
    // idle
    double h0 = r * (small ? 0.18 : 0.12);
    wi += a->w[0] * (small ? bw : h0); hi += a->w[0] * h0; ai += a->w[0] * 0.75;
    // listening
    double osc = 0.5 + 0.5 * sin(clk * 7.0 + i * 1.3);
    double h1 = r * (0.14 + 0.72 * a->level * (0.35 + 0.65 * osc) * env[i]);
    wi += a->w[1] * bw; hi += a->w[1] * h1; ai += a->w[1] * 0.96;
    // transcribing
    double dot = r * (small ? 0.2 : 0.17);
    bool is_dot = i >= 1 && i <= 3;
    wi += a->w[2] * (is_dot ? dot : bw * 0.4);
    hi += a->w[2] * (is_dot ? dot : bw * 0.4);
    yi += a->w[2] * (is_dot ? sin(clk * 6.0 - i * 0.9) * r * 0.16 : 0);
    ai += a->w[2] * (is_dot ? 0.95 : 0);
    *w = fmax(wi, 0.5);
    *h = fmax(hi, *w);
    *dy = yi;
    *alpha = ai;
}

double orb_breathe(const OrbAnim *a) { return 1.0 + 0.016 * sin(a->clock * 2 * M_PI / 6.0); }

double orb_bloom_alpha(const OrbAnim *a) { return 0.22 + 0.2 * a->w[1] * (0.4 + a->level) + 0.08 * a->w[2]; }

void orb_ripple(const OrbAnim *a, int k, double *progress, double *alpha) {
    double p = fmod(a->clock / 1.8 + k / 3.0, 1.0);
    *progress = p;
    *alpha = pow(1 - p, 1.6) * 0.35 * a->w[1] * (0.4 + a->level);
}

static inline double clamp01(double v) { return v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v); }

static inline void blend_over(double *dr, double *dg, double *db, double *da, double sr, double sg, double sb, double sa) {
    sa = clamp01(sa);
    if (sa <= 0.0) return;
    double inv = 1.0 - sa;
    *dr = sr * sa + (*dr) * inv;
    *dg = sg * sa + (*dg) * inv;
    *db = sb * sa + (*db) * inv;
    *da = sa + (*da) * inv;
}

static double sd_rounded_box(double px, double py, double bx, double by, double r) {
    double qx = fabs(px) - bx + r;
    double qy = fabs(py) - by + r;
    double mx = fmax(qx, 0.0);
    double my = fmax(qy, 0.0);
    return sqrt(mx * mx + my * my) + fmin(fmax(qx, qy), 0.0) - r;
}

void orb_render_bgra(const OrbAnim *a, uint32_t *pixels, int stride, int ox, int oy, int ow, int oh, bool small) {
    double cx = ox + ow * 0.5;
    double cy = oy + oh * 0.5;
    double r = (small ? ow * 0.5 - 1.0 : ow * 0.32) * orb_breathe(a);
    double glow = orb_bloom_alpha(a);

    double b_dx[6], b_dy[6], b_rad[6];
    for (int i = 0; i < 6; i++) {
        orb_blob(a, i, r, &b_dx[i], &b_dy[i], &b_rad[i]);
        // Match CoreGraphics y-up vs screen y-down
        b_dy[i] = -b_dy[i];
    }

    double bw0 = small ? r * 0.2 : r * 0.13;
    double gap = small ? r * 0.1 : r * 0.09;
    double bar_w[5], bar_h[5], bar_dy[5], bar_a[5], bar_x[5];
    for (int i = 0; i < 5; i++) {
        orb_bar(a, i, r, small, &bar_w[i], &bar_h[i], &bar_dy[i], &bar_a[i]);
        bar_dy[i] = -bar_dy[i];
        bar_x[i] = cx - (5 * bw0 + 4 * gap) * 0.5 + i * (bw0 + gap) + bw0 * 0.5;
    }

    double rip_r[3], rip_a[3];
    if (!small && a->w[1] > 0.01) {
        for (int k = 0; k < 3; k++) {
            double p;
            orb_ripple(a, k, &p, &rip_a[k]);
            rip_r[k] = r * (1.02 + 0.48 * p);
        }
    }

    double rim_w = fmax(1.0, r * 0.03);
    double head_ang = a->clock * 2.0 * M_PI / 1.65;
    double tail_len = 63.0 * M_PI / 180.0;

    for (int y = oy; y < oy + oh; y++) {
        uint32_t *row = pixels + y * stride;
        for (int x = ox; x < ox + ow; x++) {
            uint32_t dst = row[x];
            double da = ((dst >> 24) & 0xFF) / 255.0;
            double dr = ((dst >> 16) & 0xFF) / 255.0;
            double dg = ((dst >> 8) & 0xFF) / 255.0;
            double db = (dst & 0xFF) / 255.0;

            double px = x + 0.5;
            double py = y + 0.5;
            double dx = px - cx;
            double dy = py - cy;
            double dist = sqrt(dx * dx + dy * dy);

            // 1. Outer bloom
            if (!small) {
                double r1 = r * 1.55;
                if (dist < r1) {
                    double a1 = glow * (1.0 - dist / r1);
                    blend_over(&dr, &dg, &db, &da, kBlobColors[0][0], kBlobColors[0][1], kBlobColors[0][2], a1);
                }
                double r2 = r * 1.35;
                if (dist < r2) {
                    double a2 = glow * 0.6 * (1.0 - dist / r2);
                    blend_over(&dr, &dg, &db, &da, kBlobColors[1][0], kBlobColors[1][1], kBlobColors[1][2], a2);
                }
            }

            // 2. Inside the orb disc (with 1px anti-aliased edge)
            double disc_cov = clamp01(r + 0.5 - dist);
            if (disc_cov > 0.0) {
                double ir = 0.027, ig = 0.027, ib = 0.05;
                // Screen-blend the 6 blobs
                for (int i = 0; i < 6; i++) {
                    double bdx = px - (cx + b_dx[i]);
                    double bdy = py - (cy + b_dy[i]);
                    double bdist = sqrt(bdx * bdx + bdy * bdy);
                    if (bdist < b_rad[i]) {
                        double ba = 0.85 * (1.0 - bdist / b_rad[i]);
                        double sr = kBlobColors[i][0] * ba;
                        double sg = kBlobColors[i][1] * ba;
                        double sb = kBlobColors[i][2] * ba;
                        ir = 1.0 - (1.0 - ir) * (1.0 - sr);
                        ig = 1.0 - (1.0 - ig) * (1.0 - sg);
                        ib = 1.0 - (1.0 - ib) * (1.0 - sb);
                    }
                }
                // Edge darkening (0.55..1.0 -> alpha 0..0.55)
                double norm_d = dist / r;
                if (norm_d > 0.55) {
                    double shade_a = clamp01((norm_d - 0.55) / 0.45) * 0.55;
                    ir *= (1.0 - shade_a);
                    ig *= (1.0 - shade_a);
                    ib *= (1.0 - shade_a);
                }
                // Top soft highlight
                if (!small) {
                    double hdx = dx;
                    double hdy = py - (cy - r * 0.8);
                    double hdist = sqrt(hdx * hdx + hdy * hdy);
                    double hrad = r * 0.9;
                    if (hdist < hrad) {
                        double ha = 0.2 * (1.0 - hdist / hrad);
                        ir = ir * (1.0 - ha) + ha;
                        ig = ig * (1.0 - ha) + ha;
                        ib = ib * (1.0 - ha) + ha;
                    }
                }
                // Center glyph shade
                double g_rad = r * 0.6;
                if (dist < g_rad) {
                    double ga = 0.3 * (1.0 - dist / g_rad);
                    ir *= (1.0 - ga);
                    ig *= (1.0 - ga);
                    ib *= (1.0 - ga);
                }
                // Five voice bars / three dots
                for (int i = 0; i < 5; i++) {
                    if (bar_a[i] <= 0.005) continue;
                    double bpx = px - bar_x[i];
                    double bpy = py - (cy + bar_dy[i]);
                    double sd = sd_rounded_box(bpx, bpy, bar_w[i] * 0.5, bar_h[i] * 0.5, bar_w[i] * 0.5);
                    double bcov = clamp01(0.5 - sd) * bar_a[i];
                    if (bcov > 0.0) {
                        ir = ir * (1.0 - bcov) + 0.96 * bcov;
                        ig = ig * (1.0 - bcov) + 0.96 * bcov;
                        ib = ib * (1.0 - bcov) + 0.97 * bcov;
                    }
                }

                blend_over(&dr, &dg, &db, &da, ir, ig, ib, disc_cov);
            }

            // 3. Rim stroke
            double rim_dist = fabs(dist - r);
            if (rim_dist < rim_w * 0.5 + 0.5) {
                double rcov = clamp01(rim_w * 0.5 + 0.5 - rim_dist) * 0.22;
                blend_over(&dr, &dg, &db, &da, 1.0, 1.0, 1.0, rcov);
            }

            // 4. Ripples & transcribing arc
            if (!small) {
                if (a->w[1] > 0.01) {
                    for (int k = 0; k < 3; k++) {
                        double rd = fabs(dist - rip_r[k]);
                        if (rd < 1.0) {
                            double rcov = (1.0 - rd) * rip_a[k];
                            blend_over(&dr, &dg, &db, &da, 0.0, 0.831, 1.0, rcov);
                        }
                    }
                }
                if (a->w[2] > 0.01) {
                    double arc_r = r + 1.5;
                    double ad = fabs(dist - arc_r);
                    if (ad < 1.5) {
                        double ang = atan2(dy, dx);
                        double diff = fmod(ang - head_ang, 2.0 * M_PI);
                        if (diff < 0) diff += 2.0 * M_PI;
                        if (diff <= tail_len) {
                            double acov = clamp01(1.5 - ad) * (1.0 - diff / tail_len) * 0.9 * a->w[2];
                            blend_over(&dr, &dg, &db, &da, 0.75, 0.95, 1.0, acov);
                        }
                    }
                }
            }

            uint8_t out_a = (uint8_t)(clamp01(da) * 255.0 + 0.5);
            uint8_t out_r = (uint8_t)(clamp01(dr) * 255.0 + 0.5);
            uint8_t out_g = (uint8_t)(clamp01(dg) * 255.0 + 0.5);
            uint8_t out_b = (uint8_t)(clamp01(db) * 255.0 + 0.5);
            row[x] = ((uint32_t)out_a << 24) | ((uint32_t)out_r << 16) | ((uint32_t)out_g << 8) | (uint32_t)out_b;
        }
    }
}
