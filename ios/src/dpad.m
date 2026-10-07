/**
 * @file	dpad.m
 * @brief	On-screen cross keys (PC-98 arrow keys)
 *
 * The direction is taken from where the finger is relative to the centre
 * (with a small dead zone), so sliding from one arm to another switches the
 * arrow without lifting. Held keys repeat like a real keyboard (the PC-98
 * keyboard emulation does that).
 */

#include "compiler.h"
#include "dpad.h"
#include "keyinput.h"

typedef NS_ENUM(NSInteger, DPadDir) {
	DPadNone = -1,
	DPadUp,
	DPadDown,
	DPadLeft,
	DPadRight
};

static const UINT8 s_keys[] = {PC98KEY_UP, PC98KEY_DOWN, PC98KEY_LEFT, PC98KEY_RIGHT};

@implementation NP2DPad {
	DPadDir _pressed;
}

- (instancetype)initWithFrame:(CGRect)frame
{
	self = [super initWithFrame:frame];
	if (self) {
		_pressed = DPadNone;
		self.opaque = NO;
		self.backgroundColor = UIColor.clearColor;
		self.multipleTouchEnabled = NO;
		self.contentMode = UIViewContentModeRedraw;
		self.isAccessibilityElement = YES;
		self.accessibilityLabel = @"十字キー";
	}
	return self;
}

- (void)setOverlay:(BOOL)overlay
{
	_overlay = overlay;
	[self setNeedsDisplay];
}

// ---- input

- (DPadDir)directionAt:(CGPoint)point
{
	CGFloat size = MIN(self.bounds.size.width, self.bounds.size.height);
	CGFloat dx = point.x - CGRectGetMidX(self.bounds);
	CGFloat dy = point.y - CGRectGetMidY(self.bounds);
	if (hypot(dx, dy) < size * 0.12) {
		return DPadNone;
	}
	if (fabs(dx) > fabs(dy)) {
		return (dx < 0) ? DPadLeft : DPadRight;
	}
	return (dy < 0) ? DPadUp : DPadDown;
}

- (void)press:(DPadDir)dir
{
	if (dir == _pressed) {
		return;
	}
	if (_pressed != DPadNone) {
		keyinput_up(s_keys[_pressed]);
	}
	_pressed = dir;
	if (_pressed != DPadNone) {
		keyinput_down(s_keys[_pressed]);
	}
	[self setNeedsDisplay];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	[self press:[self directionAt:[touches.anyObject locationInView:self]]];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	[self press:[self directionAt:[touches.anyObject locationInView:self]]];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	[self press:DPadNone];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	[self press:DPadNone];
}

- (void)tapDirection:(NSString *)name
{
	NSArray<NSString *> *names = @[ @"up", @"down", @"left", @"right" ];
	NSUInteger index = [names indexOfObject:name];
	if (index == NSNotFound) {
		return;
	}
	[self press:(DPadDir)index];
	[self press:DPadNone];
}

- (void)willMoveToWindow:(UIWindow *)window
{
	if (window == nil) {
		[self press:DPadNone];
	}
}

- (void)setHidden:(BOOL)hidden
{
	if (hidden) {
		[self press:DPadNone];
	}
	[super setHidden:hidden];
}

// ---- drawing

- (void)drawRect:(CGRect)rect
{
	CGFloat size = MIN(self.bounds.size.width, self.bounds.size.height);
	CGFloat arm = size / 3;
	CGFloat x0 = CGRectGetMidX(self.bounds) - size / 2;
	CGFloat y0 = CGRectGetMidY(self.bounds) - size / 2;
	CGFloat alpha = _overlay ? 0.45 : 1.0;

	/* the cross */
	UIBezierPath *cross = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(x0 + arm, y0, arm, size) cornerRadius:arm * 0.2];
	[cross appendPath:[UIBezierPath bezierPathWithRoundedRect:CGRectMake(x0, y0 + arm, size, arm) cornerRadius:arm * 0.2]];
	[[UIColor colorWithWhite:0.30 alpha:alpha] setFill];
	[cross fill];

	/* the pressed arm */
	if (_pressed != DPadNone) {
		CGRect arms[] = {
			CGRectMake(x0 + arm, y0, arm, arm),				/* up */
			CGRectMake(x0 + arm, y0 + arm * 2, arm, arm),	/* down */
			CGRectMake(x0, y0 + arm, arm, arm),				/* left */
			CGRectMake(x0 + arm * 2, y0 + arm, arm, arm),	/* right */
		};
		[[UIColor colorWithWhite:0.60 alpha:alpha] setFill];
		[[UIBezierPath bezierPathWithRoundedRect:arms[_pressed] cornerRadius:arm * 0.2] fill];
	}

	/* arrow heads */
	[[UIColor colorWithWhite:1.0 alpha:_overlay ? 0.8 : 1.0] setFill];
	CGFloat cx = CGRectGetMidX(self.bounds);
	CGFloat cy = CGRectGetMidY(self.bounds);
	CGFloat d = arm;				/* distance from the centre */
	CGFloat t = arm * 0.22;			/* half the width of an arrow head */
	CGPoint heads[4][3] = {
		{{cx, cy - d - t}, {cx - t, cy - d + t * 0.6}, {cx + t, cy - d + t * 0.6}},
		{{cx, cy + d + t}, {cx - t, cy + d - t * 0.6}, {cx + t, cy + d - t * 0.6}},
		{{cx - d - t, cy}, {cx - d + t * 0.6, cy - t}, {cx - d + t * 0.6, cy + t}},
		{{cx + d + t, cy}, {cx + d - t * 0.6, cy - t}, {cx + d - t * 0.6, cy + t}},
	};
	for (int i = 0; i < 4; i++) {
		UIBezierPath *head = [UIBezierPath bezierPath];
		[head moveToPoint:heads[i][0]];
		[head addLineToPoint:heads[i][1]];
		[head addLineToPoint:heads[i][2]];
		[head closePath];
		[head fill];
	}
}

/* Only the cross itself takes touches (the corners pass them through). */
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event
{
	CGFloat size = MIN(self.bounds.size.width, self.bounds.size.height);
	CGFloat dx = fabs(point.x - CGRectGetMidX(self.bounds));
	CGFloat dy = fabs(point.y - CGRectGetMidY(self.bounds));
	if (dx > size / 2 || dy > size / 2) {
		return NO;
	}
	return dx <= size / 6 || dy <= size / 6;
}

@end
