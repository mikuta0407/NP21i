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

/* Fills the view's height, which is not from heightForWidth: (the lower
 * half of a folded iPhone Duo): the rows grow, up to a key a little taller
 * than wide, and the keys are centered in what is left. */
@property (nonatomic) BOOL fillsHeight;

/* Buttons along the top to switch to another keyboard (nil: none), the
 * one shown selected, and what a tap on another does. When the blocks are
 * paged, their tabs share the row. */
@property (nonatomic, copy, nullable) NSArray<NSString *> *switchTitles;
@property (nonatomic) NSInteger switchIndex;
@property (nonatomic, copy, nullable) void (^onSwitch)(NSInteger index);

/* A handle along the top edge: dragging it reports how far (points, down
 * positive) since the drag began, and whether it ended; a double tap asks
 * for the standard height. The owner sets the frame. */
@property (nonatomic) BOOL showsResizeHandle;
@property (nonatomic, copy, nullable) void (^onResize)(CGFloat dy, BOOL ended);
@property (nonatomic, copy, nullable) void (^onResetSize)(void);

/* A light tap felt on each key press (default YES). */
@property (nonatomic) BOOL hapticFeedback;
/* Character keys show what they type, larger, above the finger while
 * pressed (default YES). */
@property (nonatomic) BOOL keyPreview;

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
/* Testing: holds it down that long. */
- (BOOL)holdKey:(NSString *)identifier seconds:(NSTimeInterval)seconds;
/* Testing: shows a block when they are shown one at a time. */
- (void)showBlock:(NSInteger)index;

@end

NS_ASSUME_NONNULL_END
