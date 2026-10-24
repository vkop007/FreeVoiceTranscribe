// GPU-composited version of the orb for the floating pill. The look and motion come from
// orb.h; here every element is a Core Animation layer whose properties are updated per tick,
// so no pixels are redrawn on the CPU.
#ifndef ORBVIEW_H
#define ORBVIEW_H
#import <Cocoa/Cocoa.h>
#include "orb.h"

@interface OrbLayerView : NSView
- (void)applyAnim:(const OrbAnim *)a;
@end
#endif
