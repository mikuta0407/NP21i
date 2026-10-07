/**
 * @file	dpad.h
 * @brief	On-screen cross keys (PC-98 arrow keys)
 */

#pragma once

#import <UIKit/UIKit.h>

/* Press and hold like a game pad: the arrow under the finger is held down
 * and changes as the finger slides; lifting the finger releases it. */
@interface NP2DPad : UIView

/* Drawn half transparent over the PC-98 screen (landscape). */
@property (nonatomic) BOOL overlay;

/* Testing: presses and releases an arrow ("up", "down", "left", "right"). */
- (void)tapDirection:(NSString *)name;

@end
