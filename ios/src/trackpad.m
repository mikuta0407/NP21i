/**
 * @file	trackpad.m
 * @brief	The emulator screen used as a trackpad for the PC-98 mouse
 *
 * Moves and buttons go straight to mousemng, which the PC-98 mouse reads
 * (SDL and UIKit share the main thread). A click holds the button for a
 * moment: the guest reads the mouse at its own pace, and would miss a press
 * and release made at once.
 */

#include "compiler.h"
#include "trackpad.h"
#include "sdlcompat.h"
#include <mousemng.h>
#include <embed/vramhdl.h>
#include <embed/menubase/menubase.h>

static const CGFloat kTapTravel = 8;				/* points */
static const NSTimeInterval kTapDuration = 0.3;
static const NSTimeInterval kDragHold = 0.45;
static const NSTimeInterval kClickHold = 0.1;
/* Faster strokes go further: up to (1 + kMaxBoost) times, from kBoostFrom
 * points a second, at full boost kBoostRange above it. */
static const CGFloat kBoostFrom = 300;
static const CGFloat kBoostRange = 1200;
static const CGFloat kMaxBoost = 1.5;

static void set_button(UINT8 bit, BOOL pressed)
{
	if (pressed) {
		mousemng.btn &= ~bit;
	}
	else {
		mousemng.btn |= bit;
	}
}

@implementation NP2TrackpadView {
	NSMapTable<UITouch *, NSValue *> *_touches;	/* last location of each finger */
	NSInteger _maximumTouches;
	CGFloat _travel;
	NSTimeInterval _startTime;
	NSTimeInterval _lastTime;
	CGPoint _remainder;			/* fractions of a PC-98 pixel not moved yet */
	BOOL _dragging;
	NSTimer *_dragTimer;
	UIImpactFeedbackGenerator *_haptics;
}

- (instancetype)initWithFrame:(CGRect)frame
{
	self = [super initWithFrame:frame];
	if (self) {
		self.backgroundColor = UIColor.clearColor;
		self.multipleTouchEnabled = YES;
		_pointsPerPixel = 1;
		_speed = 1;
		_touches = [NSMapTable strongToStrongObjectsMapTable];
		_haptics = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
	}
	return self;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
	/* the NP2 menu is used where it is drawn (SDL) */
	if (menuvram != NULL) {
		return nil;
	}
	return [super hitTest:point withEvent:event];
}

- (void)setHidden:(BOOL)hidden
{
	if (hidden) {
		[self reset];
	}
	[super setHidden:hidden];
}

- (void)reset
{
	[self disarmDrag];
	if (_dragging) {
		_dragging = NO;
		set_button(uPD8255A_LEFTBIT, NO);
	}
	[_touches removeAllObjects];
	_maximumTouches = 0;
	_travel = 0;
}

// ---- touches

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	for (UITouch *touch in touches) {
		if (_touches.count == 0) {
			[self reset];
			_startTime = touch.timestamp;
			_lastTime = touch.timestamp;
		}
		[_touches setObject:[NSValue valueWithCGPoint:[touch locationInView:self]] forKey:touch];
	}
	_maximumTouches = MAX(_maximumTouches, (NSInteger)_touches.count);
	[self disarmDrag];
	if (_touches.count == 1) {
		__weak NP2TrackpadView *weakSelf = self;
		_dragTimer = [NSTimer scheduledTimerWithTimeInterval:kDragHold repeats:NO block:^(NSTimer *timer) {
			[weakSelf beginDrag];
		}];
	}
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	CGPoint sum = CGPointZero;
	NSInteger count = 0;
	NSTimeInterval timestamp = _lastTime;
	for (UITouch *touch in touches) {
		NSValue *previous = [_touches objectForKey:touch];
		if (previous == nil) {
			continue;
		}
		CGPoint location = [touch locationInView:self];
		sum.x += location.x - previous.CGPointValue.x;
		sum.y += location.y - previous.CGPointValue.y;
		[_touches setObject:[NSValue valueWithCGPoint:location] forKey:touch];
		count++;
		timestamp = MAX(timestamp, touch.timestamp);
	}
	if (count == 0) {
		return;
	}
	CGPoint delta = CGPointMake(sum.x / count, sum.y / count);
	CGFloat distance = hypot(delta.x, delta.y);
	_travel += distance;
	NSTimeInterval elapsed = MAX(timestamp - _lastTime, 1.0 / 240);
	_lastTime = timestamp;
	if (_travel >= kTapTravel && !_dragging) {
		[self disarmDrag];
	}
	/* two fingers would scroll; the PC-98 mouse has no wheel */
	if (_touches.count >= 2 && !_dragging) {
		return;
	}
	CGFloat boost = MIN(MAX((distance / elapsed - kBoostFrom) / kBoostRange, 0), 1) * kMaxBoost;
	CGFloat gain = (1 + boost) * _speed / MAX(_pointsPerPixel, 0.01);
	_remainder.x += delta.x * gain;
	_remainder.y += delta.y * gain;
	int dx = (int)_remainder.x;
	int dy = (int)_remainder.y;
	_remainder.x -= dx;
	_remainder.y -= dy;
	if (dx || dy) {
		mousemng_sync(dx, dy);
	}
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	[self finishTouches:touches cancelled:NO];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	[self finishTouches:touches cancelled:YES];
}

- (void)finishTouches:(NSSet<UITouch *> *)touches cancelled:(BOOL)cancelled
{
	NSTimeInterval timestamp = 0;
	for (UITouch *touch in touches) {
		[_touches removeObjectForKey:touch];
		timestamp = MAX(timestamp, touch.timestamp);
	}
	if (_touches.count > 0) {
		return;
	}
	BOOL tap = !cancelled && !_dragging && _travel < kTapTravel && timestamp - _startTime < kTapDuration;
	if (tap) {
		[_haptics impactOccurred];
		[self click:(_maximumTouches >= 2) ? uPD8255A_RIGHTBIT : uPD8255A_LEFTBIT];
	}
	[self reset];
}

// ---- buttons

- (void)click:(UINT8)bit
{
	set_button(bit, YES);
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kClickHold * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		set_button(bit, NO);
	});
}

- (void)disarmDrag
{
	[_dragTimer invalidate];
	_dragTimer = nil;
}

- (void)beginDrag
{
	_dragTimer = nil;
	if (_touches.count != 1 || _travel >= kTapTravel || _dragging) {
		return;
	}
	_dragging = YES;
	[_haptics impactOccurredWithIntensity:1];
	set_button(uPD8255A_LEFTBIT, YES);
}

@end
