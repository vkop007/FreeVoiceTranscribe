#import "orb.h"
#include <math.h>

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
    double clk = a->clock;
    r *= orb_breathe(a);
    static const double black[3] = {0, 0, 0}, white[3] = {1, 1, 1}, cyan[3] = {0.0, 0.831, 1.0};

    CGContextSaveGState(ctx);
    CGContextSetAllowsAntialiasing(ctx, true);

    // Outer bloom.
    if (!small) {
        double glow = orb_bloom_alpha(a);
        fill_radial(ctx, cs, c, r * 1.55, orb_blob_color(0), glow, 0);
        fill_radial(ctx, cs, c, r * 1.35, orb_blob_color(1), glow * 0.6, 0);
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
        fill_radial(ctx, cs, CGPointMake(c.x + dx, c.y + dy), br, orb_blob_color(i), 0.85, 0);
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
