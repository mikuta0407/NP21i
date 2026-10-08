/**
 * @file	trackpad.h
 * @brief	The emulator screen used as a trackpad for the PC-98 mouse
 */

#pragma once

#import <UIKit/UIKit.h>

/* Laid over the emulator screen, under the other controls, while touches
 * are to be a trackpad's (otherwise SDL takes them: the pointer goes where
 * the finger is, the left button held while touched). Modelled on mRemote's
 * TrackpadGestureTracker:
 *
 * - one finger moves the mouse, by travel rather than position;
 * - a tap is a left click, a two-finger tap a right click;
 * - a finger held still and then moved drags with the left button.
 *
 * The NP2 menu still takes touches where they are. */
@interface NP2TrackpadView : UIView

/* Screen points per PC-98 pixel, so a finger and the pointer travel alike. */
@property (nonatomic) CGFloat pointsPerPixel;
/* The user's factor on that (1 = alike). */
@property (nonatomic) CGFloat speed;

/* Lets go of a drag's button (when hidden or turned off). */
- (void)reset;

@end
