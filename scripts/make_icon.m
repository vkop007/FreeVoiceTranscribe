// Renders the app icon (the listening orb on a dark glass tile) into an .iconset folder.
// Usage: make_icon <out.iconset>   (then: iconutil -c icns <out.iconset>)
#import <Cocoa/Cocoa.h>
#import "../src/orb.h"

static void render(NSString *dir, int px, NSString *name) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, px, px, 8, 0, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    double s = px / 1024.0;
    CGContextScaleCTM(ctx, s, s);

    // macOS icon grid: 824pt tile centred in a 1024pt canvas, ~22% corner radius.
    CGRect tile = CGRectMake(100, 100, 824, 824);
    CGPathRef path = CGPathCreateWithRoundedRect(tile, 185, 185, NULL);
    CGContextSaveGState(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0, -10), 24, [NSColor colorWithWhite:0 alpha:0.45].CGColor);
    CGContextAddPath(ctx, path);
    CGContextSetRGBFillColor(ctx, 0.03, 0.03, 0.05, 1);
    CGContextFillPath(ctx);
    CGContextRestoreGState(ctx);

    CGContextSaveGState(ctx);
    CGContextAddPath(ctx, path);
    CGContextClip(ctx);
    CGFloat comps[8] = {0.10, 0.10, 0.16, 1, 0.02, 0.02, 0.04, 1};
    CGGradientRef g = CGGradientCreateWithColorComponents(cs, comps, (CGFloat[]){0, 1}, 2);
    CGContextDrawLinearGradient(ctx, g, CGPointMake(512, 924), CGPointMake(512, 100), 0);
    CGGradientRelease(g);

    OrbAnim a;
    orb_init(&a);
    a.w[0] = 0; a.w[1] = 1; a.w[2] = 0;
    a.level = 0.45; a.blob_t = 1.6; a.clock = 0.35;
    double side = 330.0 / 0.32 * 1.0; // orb radius ~330pt
    orb_draw(&a, ctx, CGRectMake(512 - side / 2, 512 - side / 2, side, side), false);
    CGContextRestoreGState(ctx);

    // Hairline edge on the tile.
    CGContextAddPath(ctx, path);
    CGContextSetRGBStrokeColor(ctx, 1, 1, 1, 0.12);
    CGContextSetLineWidth(ctx, 3);
    CGContextStrokePath(ctx);
    CGPathRelease(path);

    CGImageRef img = CGBitmapContextCreateImage(ctx);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[dir stringByAppendingPathComponent:name] atomically:YES];
    CGImageRelease(img);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *dir = [NSString stringWithUTF8String:argv[1]];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        int sizes[] = {16, 32, 128, 256, 512};
        for (int i = 0; i < 5; i++) {
            render(dir, sizes[i], [NSString stringWithFormat:@"icon_%dx%d.png", sizes[i], sizes[i]]);
            render(dir, sizes[i] * 2, [NSString stringWithFormat:@"icon_%dx%d@2x.png", sizes[i], sizes[i]]);
        }
    }
    return 0;
}
