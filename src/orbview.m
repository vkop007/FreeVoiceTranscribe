#import "orbview.h"
#import <QuartzCore/QuartzCore.h>

typedef struct { double loc, r, g, b, a; } Stop;

// Renders a radial gradient (centre to edge) into an image once; layers then scale and blend it.
static CGImageRef make_radial(int px, const Stop *stops, int n) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, px, px, 8, 0, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGFloat comps[5 * 4], locs[5];
    for (int i = 0; i < n; i++) {
        comps[i * 4] = stops[i].r; comps[i * 4 + 1] = stops[i].g; comps[i * 4 + 2] = stops[i].b; comps[i * 4 + 3] = stops[i].a;
        locs[i] = stops[i].loc;
    }
    CGGradientRef g = CGGradientCreateWithColorComponents(cs, comps, locs, n);
    CGPoint c = CGPointMake(px / 2.0, px / 2.0);
    CGContextDrawRadialGradient(ctx, g, c, 0, c, px / 2.0, 0);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGGradientRelease(g);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    return img;
}

static CALayer *layer_with(CGImageRef img, CGFloat scale) {
    CALayer *l = [CALayer layer];
    l.contents = (__bridge id)img;
    l.contentsScale = scale;
    return l;
}

@implementation OrbLayerView {
    CALayer *_bloom, *_bloom2, *_group, *_disc, *_glyphShade, *_rim;
    CALayer *_blobs[6], *_bars[5], *_ripples[3];
    CAGradientLayer *_arc;
    CGFloat _r;       // orb radius
    CGPoint _c;
    CGFloat _blobBase;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.wantsLayer = YES;
    CALayer *root = self.layer;
    root.masksToBounds = NO;
    CGFloat scale = NSScreen.mainScreen.backingScaleFactor ?: 2;
    _c = CGPointMake(frame.size.width / 2, frame.size.height / 2);
    _r = frame.size.width * 0.32;
    CGFloat d = _r * 2;

    // Bloom: two soft glows behind the disc.
    CGImageRef violet = make_radial(256, (Stop[]){{0, 0.486, 0.361, 1, 1}, {1, 0.486, 0.361, 1, 0}}, 2);
    CGImageRef cyan = make_radial(256, (Stop[]){{0, 0.0, 0.831, 1, 1}, {1, 0.0, 0.831, 1, 0}}, 2);
    _bloom = layer_with(violet, scale);
    _bloom.bounds = CGRectMake(0, 0, _r * 3.1, _r * 3.1);
    _bloom.position = _c;
    _bloom2 = layer_with(cyan, scale);
    _bloom2.bounds = CGRectMake(0, 0, _r * 2.7, _r * 2.7);
    _bloom2.position = _c;
    [root addSublayer:_bloom];
    [root addSublayer:_bloom2];
    CGImageRelease(violet);
    CGImageRelease(cyan);

    for (int k = 0; k < 3; k++) {
        CALayer *l = [CALayer layer];
        l.bounds = CGRectMake(0, 0, d, d);
        l.position = _c;
        l.cornerRadius = _r;
        l.borderWidth = 1;
        l.borderColor = CGColorCreateGenericRGB(0, 0.831, 1, 1);
        l.opacity = 0;
        [root addSublayer:l];
        _ripples[k] = l;
    }

    _group = [CALayer layer]; // scaled for breathing
    _group.bounds = CGRectMake(0, 0, d, d);
    _group.position = _c;
    [root addSublayer:_group];

    _disc = [CALayer layer];
    _disc.frame = _group.bounds;
    _disc.cornerRadius = _r;
    _disc.masksToBounds = YES;
    _disc.backgroundColor = CGColorCreateGenericRGB(0.027, 0.027, 0.05, 1);
    [_group addSublayer:_disc];

    _blobBase = _r * 1.2;
    for (int i = 0; i < 6; i++) {
        const double *c = orb_blob_color(i);
        CGImageRef img = make_radial(192, (Stop[]){{0, c[0], c[1], c[2], 0.85}, {1, c[0], c[1], c[2], 0}}, 2);
        CALayer *l = layer_with(img, scale);
        CGImageRelease(img);
        l.bounds = CGRectMake(0, 0, _blobBase * 2, _blobBase * 2);
        l.compositingFilter = @"screenBlendMode";
        [_disc addSublayer:l];
        _blobs[i] = l;
    }

    // Glass: darker toward the rim, a soft highlight near the top, and a shade behind the glyph.
    CGImageRef shade = make_radial(256, (Stop[]){{0, 0, 0, 0, 0}, {0.55, 0, 0, 0, 0}, {1, 0, 0, 0, 0.55}}, 3);
    CALayer *shadeL = layer_with(shade, scale);
    CGImageRelease(shade);
    shadeL.frame = _disc.bounds;
    [_disc addSublayer:shadeL];

    CGImageRef hi = make_radial(192, (Stop[]){{0, 1, 1, 1, 0.2}, {1, 1, 1, 1, 0}}, 2);
    CALayer *hiL = layer_with(hi, scale);
    CGImageRelease(hi);
    hiL.bounds = CGRectMake(0, 0, _r * 1.8, _r * 1.8);
    hiL.position = CGPointMake(_r, _r * 1.8);
    [_disc addSublayer:hiL];

    CGImageRef gs = make_radial(192, (Stop[]){{0, 0, 0, 0, 0.3}, {1, 0, 0, 0, 0}}, 2);
    _glyphShade = layer_with(gs, scale);
    CGImageRelease(gs);
    _glyphShade.bounds = CGRectMake(0, 0, _r * 1.2, _r * 1.2);
    _glyphShade.position = CGPointMake(_r, _r);
    [_disc addSublayer:_glyphShade];

    for (int i = 0; i < 5; i++) {
        CALayer *l = [CALayer layer];
        l.backgroundColor = CGColorCreateGenericRGB(0.96, 0.96, 0.97, 1);
        [_disc addSublayer:l];
        _bars[i] = l;
    }

    _rim = [CALayer layer];
    _rim.frame = _group.bounds;
    _rim.cornerRadius = _r;
    _rim.borderWidth = fmax(1.0, _r * 0.03);
    _rim.borderColor = CGColorCreateGenericRGB(1, 1, 1, 0.22);
    [_group addSublayer:_rim];

    // Orbiting light arc: a conic gradient (bright head, fading tail) masked to a thin ring.
    _arc = [CAGradientLayer layer];
    _arc.type = kCAGradientLayerConic;
    CGFloat ad = (_r + 1.5) * 2 + 4;
    _arc.bounds = CGRectMake(0, 0, ad, ad);
    _arc.position = _c;
    _arc.startPoint = CGPointMake(0.5, 0.5);
    _arc.endPoint = CGPointMake(0.5, 1.0);
    CGColorRef clear = CGColorCreateGenericRGB(0.75, 0.95, 1, 0);
    CGColorRef head = CGColorCreateGenericRGB(0.75, 0.95, 1, 0.9);
    _arc.colors = @[(__bridge id)clear, (__bridge id)clear, (__bridge id)head];
    _arc.locations = @[@0, @0.825, @1.0];
    CAShapeLayer *ring = [CAShapeLayer layer];
    ring.frame = _arc.bounds;
    ring.path = CGPathCreateWithEllipseInRect(CGRectMake(2, 2, ad - 4, ad - 4), NULL);
    ring.fillColor = nil;
    ring.strokeColor = CGColorGetConstantColor(kCGColorBlack);
    ring.lineWidth = 2;
    _arc.mask = ring;
    _arc.opacity = 0;
    [root addSublayer:_arc];
    return self;
}

- (void)applyAnim:(const OrbAnim *)a {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    double breathe = orb_breathe(a);
    _group.transform = CATransform3DMakeScale(breathe, breathe, 1);

    double glow = orb_bloom_alpha(a);
    _bloom.opacity = (float)glow;
    _bloom2.opacity = (float)(glow * 0.6);

    for (int i = 0; i < 6; i++) {
        double dx, dy, rad;
        orb_blob(a, i, _r, &dx, &dy, &rad);
        _blobs[i].position = CGPointMake(_r + dx, _r + dy);
        double s = rad / _blobBase;
        _blobs[i].transform = CATransform3DMakeScale(s, s, 1);
    }

    double bw0 = _r * 0.13, gap = _r * 0.09;
    for (int i = 0; i < 5; i++) {
        double w, h, dy, alpha;
        orb_bar(a, i, _r, false, &w, &h, &dy, &alpha);
        double x = _r - (5 * bw0 + 4 * gap) / 2 + i * (bw0 + gap) + bw0 / 2;
        _bars[i].bounds = CGRectMake(0, 0, w, h);
        _bars[i].cornerRadius = w / 2;
        _bars[i].position = CGPointMake(x, _r + dy);
        _bars[i].opacity = (float)alpha;
    }

    for (int k = 0; k < 3; k++) {
        double p, al;
        orb_ripple(a, k, &p, &al);
        double s = 1.02 + 0.48 * p;
        _ripples[k].transform = CATransform3DMakeScale(s, s, 1);
        _ripples[k].opacity = (float)al;
    }

    _arc.opacity = (float)a->w[2];
    if (a->w[2] > 0.01) _arc.transform = CATransform3DMakeRotation(-a->clock * 2 * M_PI / 1.65, 0, 0, 1);
    [CATransaction commit];
}

@end
