/**
 * @file	kbdview.h
 * @brief	On-screen keyboard drawn by the app (any NP2KeyboardLayout)
 */

#pragma once

#import <UIKit/UIKit.h>
#import "kbdlayout.h"

NS_ASSUME_NONNULL_BEGIN

/* A picture of a keyboard: each key is a PC-98 key position, pressed while
 * touched, so it types whatever the guest makes of it, as a real keyboard
 * would. All touches go to this one view, so a finger can hold SHIFT while
 * another taps a key.
 *
 * The blocks of the layout are shown side by side when they fit the width,
 * else one at a time with tabs above them. */
@interface NP2KeyboardView : UIView

@property (nonatomic, strong) NP2KeyboardLayout *layout;

- (instancetype)initWithLayout:(NP2KeyboardLayout *)layout;

/* The height the keyboard wants for a width, not more than maxHeight. */
- (CGFloat)heightForWidth:(CGFloat)width maxHeight:(CGFloat)maxHeight;

/* Lets go of every key held by a finger (when hidden or changed). */
- (void)releaseAll;

/* Redraws modifier and lock states (they also change from other keys). */
- (void)refreshStates;

/* Testing: taps the key with this identifier ("1e", "ret", "shift", ...),
 * on the block shown. */
- (BOOL)tapKey:(NSString *)identifier;
/* Testing: shows a block when they are shown one at a time. */
- (void)showBlock:(NSInteger)index;

@end

NS_ASSUME_NONNULL_END
