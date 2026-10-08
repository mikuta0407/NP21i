/**
 * @file	scanlines.m
 * @brief	Dark lines between the PC-98 screen's lines, like a CRT
 *
 * Drawn as rectangles rather than a repeating image: a line is rarely a
 * whole number of device pixels tall, and a pattern would drift off the
 * screen's lines over 400 of them.
 */

#include "scanlines.h"

static const CGFloat kBand = 0.45;		/* of a line, dark */
static const CGFloat kDarkness = 0.38;

@implementation NP2ScanlineView {
	CGFloat _lines;
	CGFloat _offset;
}

- (instancetype)initWithFrame:(CGRect)frame
{
	self = [super initWithFrame:frame];
	if (self) {
		self.opaque = NO;
		self.backgroundColor = UIColor.clearColor;
		self.userInteractionEnabled = NO;
		self.isAccessibilityElement = NO;
		self.contentMode = UIViewContentModeRedraw;
		_lines = 400;
	}
	return self;
}

- (void)setLines:(CGFloat)lines firstLineOffset:(CGFloat)offset
{
	if (lines != _lines || offset != _offset) {
		_lines = lines;
		_offset = offset;
		[self setNeedsDisplay];
	}
}

- (void)drawRect:(CGRect)rect
{
	CGFloat height = self.bounds.size.height;
	if (_lines <= 0 || height <= 0) {
		return;
	}
	CGFloat line = height / _lines;
	if (line < 1.5) {
		return;		/* too fine to show (a small screen) */
	}
	CGContextRef context = UIGraphicsGetCurrentContext();
	CGContextSetFillColorWithColor(context, [UIColor colorWithWhite:0 alpha:kDarkness].CGColor);
	CGFloat width = self.bounds.size.width;
	for (CGFloat y = -_offset * line; y < height; y += line) {
		CGRect band = CGRectMake(0, y + line * (1 - kBand), width, line * kBand);
		if (CGRectIntersectsRect(band, rect)) {
			CGContextFillRect(context, band);
		}
	}
}

@end
