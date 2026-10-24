#import "orb.h"
#include <math.h>

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

static CGGradientRef radial_gradient(CGColorSpaceRef cs, const double c[3], double a0, double a1) {
    CGFloat comps[8] = {c[0], c[1], c[2], a0, c[0], c[1], c[2], a1};
    CGFloat locs[2] = {0, 1};
    return CGGradientCreateWithColorComponents(cs, comps, locs, 2);
}

static void fill_radial(CGContextRef ctx, CGColorSpaceRef cs, CGPoint c, double r, const double col[3], double a0, double a1) {
    CGGradientRef g = radial_gradient(cs, col, a0, a1);
    CGContextDrawRadialGradient(ctx, g, c, 0, c, r, 0);
    CGGradientRelease(g);
}

void orb_draw(const OrbAnim *a, CGContextRef ctx, CGRect bounds, bool small) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGPoint c = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    double r = small ? bounds.size.width / 2 - 1.0 : bounds.size.width * 0.32;
    double lvl = a->level, t = a->blob_t, clk = a->clock;
    r *= orb_breathe(a);
    static const double black[3] = {0, 0, 0}, white[3] = {1, 1, 1}, cyan[3] = {0.0, 0.831, 1.0};

    CGContextSaveGState(ctx);
    CGContextSetAllowsAntialiasing(ctx, true);

    // Outer bloom.
    if (!small) {
        double glow = orb_bloom_alpha(a);
        fill_radial(ctx, cs, c, r * 1.55, kBlobColors[0], glow, 0);
        fill_radial(ctx, cs, c, r * 1.35, kBlobColors[1], glow * 0.6, 0);
    }

    // Everything inside the circle.
    CGContextSaveGState(ctx);
    CGContextAddEllipseInRect(ctx, CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r));
    CGContextClip(ctx);
    CGContextSetRGBFillColor(ctx, 0.027, 0.027, 0.05, 1);
    CGContextFillRect(ctx, bounds);

    CGContextSetBlendMode(ctx, kCGBlendModeScreen);
    for (int i = 0; i < 6; i++) {
        double dx, dy, br;
        orb_blob(a, i, r, &dx, &dy, &br);
        fill_radial(ctx, cs, CGPointMake(c.x + dx, c.y + dy), br, kBlobColors[i], 0.85, 0);
    }
    CGContextSetBlendMode(ctx, kCGBlendModeNormal);

    // Glass: darken toward the rim, soft highlight near the top.
    {
        CGFloat comps3[12] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0.55};
        CGFloat locs3[3] = {0, 0.55, 1};
        CGGradientRef g = CGGradientCreateWithColorComponents(cs, comps3, locs3, 3);
        CGContextDrawRadialGradient(ctx, g, c, 0, c, r, 0);
        CGGradientRelease(g);
        if (!small) fill_radial(ctx, cs, CGPointMake(c.x, c.y + r * 0.8), r * 0.9, white, 0.2, 0);
    }

    // Soft shade behind the glyph so the bars read on bright colour.
    fill_radial(ctx, cs, c, r * 0.6, black, 0.3, 0);

    // Glyph: five bars that morph into three dots while transcribing.
    {
        double bw0 = small ? r * 0.2 : r * 0.13, gap = small ? r * 0.1 : r * 0.09;
        for (int i = 0; i < 5; i++) {
            double w, h, yoff, alpha;
            orb_bar(a, i, r, small, &w, &h, &yoff, &alpha);
            double x = c.x - (5 * bw0 + 4 * gap) / 2 + i * (bw0 + gap) + bw0 / 2;
            CGRect rr = CGRectMake(x - w / 2, c.y + yoff - h / 2, w, h);
            CGContextSetRGBFillColor(ctx, 0.96, 0.96, 0.97, alpha);
            CGPathRef path = CGPathCreateWithRoundedRect(rr, w / 2, w / 2, NULL);
            CGContextAddPath(ctx, path);
            CGContextFillPath(ctx);
            CGPathRelease(path);
        }
    }
    CGContextRestoreGState(ctx);

    // Rim.
    CGContextSetRGBStrokeColor(ctx, 1, 1, 1, 0.22);
    CGContextSetLineWidth(ctx, fmax(1.0, r * 0.03));
    CGContextStrokeEllipseInRect(ctx, CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r));

    if (!small) {
        // Ripples while listening.
        if (a->w[1] > 0.01) {
            for (int k = 0; k < 3; k++) {
                double p, al;
                orb_ripple(a, k, &p, &al);
                CGContextSetRGBStrokeColor(ctx, cyan[0], cyan[1], cyan[2], al);
                CGContextSetLineWidth(ctx, 1.0);
                double rr = r * (1.02 + 0.48 * p);
                CGContextStrokeEllipseInRect(ctx, CGRectMake(c.x - rr, c.y - rr, 2 * rr, 2 * rr));
            }
        }
        // Orbiting light arc while transcribing.
        if (a->w[2] > 0.01) {
            double head = -clk * 2 * M_PI / 1.65;
            int segs = 14;
            double tail = 63.0 * M_PI / 180.0;
            CGContextSetLineWidth(ctx, 2.0);
            CGContextSetLineCap(ctx, kCGLineCapRound);
            for (int s = 0; s < segs; s++) {
                double a0 = head + (s * tail / segs), a1 = head + ((s + 1) * tail / segs);
                double al = (1.0 - (double)s / segs) * 0.9 * a->w[2];
                CGContextSetRGBStrokeColor(ctx, 0.75, 0.95, 1, al);
                CGContextAddArc(ctx, c.x, c.y, r + 1.5, a0, a1, 0);
                CGContextStrokePath(ctx);
            }
        }
    }
    CGContextRestoreGState(ctx);
    CGColorSpaceRelease(cs);
}
