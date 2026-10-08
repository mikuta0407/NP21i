/**
 * @file	scanlines.h
 * @brief	Dark lines between the PC-98 screen's lines, like a CRT
 */

#pragma once

#import <UIKit/UIKit.h>

/* Laid exactly over the PC-98 screen, taking no touches: one dark band at
 * the bottom of each of its lines. */
@interface NP2ScanlineView : UIView

/* The screen's lines shown in the view (fewer when zoomed in), and where
 * the first of them starts: 0.3 means 30% of it is above the view. */
- (void)setLines:(CGFloat)lines firstLineOffset:(CGFloat)offset;

@end
