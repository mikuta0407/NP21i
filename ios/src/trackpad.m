/**
 * @file	trackpad.m
 * @brief	The emulator screen used as a trackpad for the PC-98 mouse
 *
 * Moves and buttons go straight to mousemng, which the PC-98 mouse reads
 * (SDL and UIKit share the main thread). A click holds the button for a
 * moment: the guest reads the mouse at its own pace, and would miss a press
 * and release made at once.
 *
 * UIKit's touches are reduced to finger samples (an identity, a location, a
 * time), so that debug scripts can stroke the pad as fingers would.
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
static const NSTimeInterval kTapDragWait = 0.35;	/* from a tap to the touch that drags */
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

static NSTimeInterval now(void)
{
	return NSProcessInfo.processInfo.systemUptime;	/* UITouch.timestamp's clock */
}

@implementation NP2TrackpadView {
	NSMutableDictionary<id, NSValue *> *_fingers;	/* last location of each finger */
	NSInteger _maximumFingers;
	CGFloat _travel;
	NSTimeInterval _startTime;
	NSTimeInterval _lastTime;
	NSTimeInterval _lastTapTime;	/* when the last tap ended (tap and drag) */
	CGPoint _remainder;				/* fractions of a PC-98 pixel not moved yet */
	BOOL _tapDrag;					/* this touch came right after a tap */
	BOOL _dragging;
	NSUInteger _clicks;				/* the last click's number, so an older one lets go of no newer */
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
		_fingers = [NSMutableDictionary dictionary];
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
	[_fingers removeAllObjects];
	_maximumFingers = 0;
	_travel = 0;
	_tapDrag = NO;
}

// ---- UIKit touches

static id finger_of(UITouch *touch)
{
	return [NSValue valueWithNonretainedObject:touch];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	for (UITouch *touch in touches) {
		[self fingerDown:finger_of(touch) at:[touch locationInView:self] time:touch.timestamp];
	}
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	NSMutableDictionary<id, NSValue *> *moves = [NSMutableDictionary dictionary];
	NSTimeInterval timestamp = 0;
	for (UITouch *touch in touches) {
		moves[finger_of(touch)] = [NSValue valueWithCGPoint:[touch locationInView:self]];
		timestamp = MAX(timestamp, touch.timestamp);
	}
	[self fingersMoved:moves time:timestamp];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	for (UITouch *touch in touches) {
		[self fingerUp:finger_of(touch) time:touch.timestamp cancelled:NO];
	}
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	for (UITouch *touch in touches) {
		[self fingerUp:finger_of(touch) time:touch.timestamp cancelled:YES];
	}
}

// ---- gesture

- (void)fingerDown:(id)finger at:(CGPoint)location time:(NSTimeInterval)timestamp
{
	if (_fingers.count == 0) {
		[self reset];
		_startTime = timestamp;
		_lastTime = timestamp;
		_tapDrag = (timestamp - _lastTapTime < kTapDragWait);
	}
	_fingers[finger] = [NSValue valueWithCGPoint:location];
	_maximumFingers = MAX(_maximumFingers, (NSInteger)_fingers.count);
	[self disarmDrag];
	if (_fingers.count == 1) {
		__weak NP2TrackpadView *weakSelf = self;
		_dragTimer = [NSTimer scheduledTimerWithTimeInterval:kDragHold repeats:NO block:^(NSTimer *timer) {
			[weakSelf beginDrag];
		}];
	}
	else {
		_tapDrag = NO;
	}
}

- (void)fingersMoved:(NSDictionary<id, NSValue *> *)moves time:(NSTimeInterval)timestamp
{
	CGPoint sum = CGPointZero;
	NSInteger count = 0;
	for (id finger in moves) {
		NSValue *previous = _fingers[finger];
		if (previous == nil) {
			continue;
		}
		CGPoint location = moves[finger].CGPointValue;
		sum.x += location.x - previous.CGPointValue.x;
		sum.y += location.y - previous.CGPointValue.y;
		_fingers[finger] = moves[finger];
		count++;
	}
	if (count == 0) {
		return;
	}
	CGPoint delta = CGPointMake(sum.x / count, sum.y / count);
	CGFloat distance = hypot(delta.x, delta.y);
	_travel += distance;
	NSTimeInterval elapsed = MAX(timestamp - _lastTime, 1.0 / 240);
	_lastTime = MAX(timestamp, _lastTime);
	if (_travel >= kTapTravel && !_dragging) {
		[self disarmDrag];
		if (_tapDrag) {
			/* tap, then touch again and move: drag */
			[self beginDrag];
		}
	}
	/* two fingers would scroll; the PC-98 mouse has no wheel */
	if (_fingers.count >= 2 && !_dragging) {
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

- (void)fingerUp:(id)finger time:(NSTimeInterval)timestamp cancelled:(BOOL)cancelled
{
	if (_fingers[finger] == nil) {
		return;
	}
	[_fingers removeObjectForKey:finger];
	if (_fingers.count > 0) {
		return;
	}
	BOOL tap = !cancelled && !_dragging && _travel < kTapTravel && timestamp - _startTime < kTapDuration;
	if (tap) {
		[_haptics impactOccurred];
		[self click:(_maximumFingers >= 2) ? uPD8255A_RIGHTBIT : uPD8255A_LEFTBIT];
		/* a tap after a tap is a double click, not the start of a drag */
		_lastTapTime = (_maximumFingers == 1 && !_tapDrag) ? timestamp : 0;
	}
	else {
		_lastTapTime = 0;
	}
	[self reset];
}

// ---- buttons

- (void)click:(UINT8)bit
{
	NSUInteger click = ++_clicks;
	set_button(bit, YES);
	__weak NP2TrackpadView *weakSelf = self;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kClickHold * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		NP2TrackpadView *pad = weakSelf;
		if (pad == nil || pad->_clicks == click) {
			set_button(bit, NO);
		}
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
	if (_fingers.count != 1 || _dragging) {
		return;
	}
	if (_travel >= kTapTravel && !_tapDrag) {
		return;
	}
	_dragging = YES;
	_clicks++;		/* a click still holding the button must not let go of the drag */
	[_haptics impactOccurredWithIntensity:1];
	set_button(uPD8255A_LEFTBIT, YES);
}

// ---- testing

/* One finger (or two) down at the middle, moved by (dx, dy) points in
 * `steps` steps over `duration` seconds after `hold` seconds, then up. */
- (void)strokeFingers:(NSInteger)fingers dx:(CGFloat)dx dy:(CGFloat)dy hold:(NSTimeInterval)hold
             duration:(NSTimeInterval)duration after:(NSTimeInterval)delay
{
	NSInteger steps = (dx || dy) ? 10 : 0;
	CGPoint start = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
	NSMutableArray<id> *ids = [NSMutableArray array];
	for (NSInteger i = 0; i < fingers; i++) {
		[ids addObject:[NSUUID UUID]];
	}
	__weak NP2TrackpadView *weakSelf = self;
	void (^later)(NSTimeInterval, void (^)(NP2TrackpadView *)) = ^(NSTimeInterval at, void (^block)(NP2TrackpadView *)) {
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(at * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			NP2TrackpadView *pad = weakSelf;
			if (pad) {
				block(pad);
			}
		});
	};
	later(delay, ^(NP2TrackpadView *pad) {
		for (NSInteger i = 0; i < fingers; i++) {
			[pad fingerDown:ids[i] at:CGPointMake(start.x + i * 40, start.y) time:now()];
		}
	});
	for (NSInteger step = 1; step <= steps; step++) {
		later(delay + hold + duration * step / steps, ^(NP2TrackpadView *pad) {
			NSMutableDictionary<id, NSValue *> *moves = [NSMutableDictionary dictionary];
			for (NSInteger i = 0; i < fingers; i++) {
				moves[ids[i]] = [NSValue valueWithCGPoint:CGPointMake(start.x + i * 40 + dx * step / steps, start.y + dy * step / steps)];
			}
			[pad fingersMoved:moves time:now()];
		});
	}
	later(delay + hold + duration + 0.02, ^(NP2TrackpadView *pad) {
		for (id finger in ids) {
			[pad fingerUp:finger time:now() cancelled:NO];
		}
	});
}

- (BOOL)debugCommand:(NSString *)command
{
	NSArray<NSString *> *parts = [command componentsSeparatedByString:@":"];
	NSArray<NSString *> *args = (parts.count > 1) ? [parts[1] componentsSeparatedByString:@"/"] : @[];
	CGFloat dx = (args.count > 0) ? args[0].doubleValue : 0;
	CGFloat dy = (args.count > 1) ? args[1].doubleValue : 0;
	NSTimeInterval duration = (args.count > 2) ? args[2].doubleValue : 0.3;
	if ([parts[0] isEqualToString:@"!padmove"]) {
		[self strokeFingers:1 dx:dx dy:dy hold:0 duration:duration after:0];
	}
	else if ([parts[0] isEqualToString:@"!padtap"]) {
		[self strokeFingers:1 dx:0 dy:0 hold:0.08 duration:0 after:0];
	}
	else if ([parts[0] isEqualToString:@"!paddoubletap"]) {
		[self strokeFingers:1 dx:0 dy:0 hold:0.08 duration:0 after:0];
		[self strokeFingers:1 dx:0 dy:0 hold:0.08 duration:0 after:0.2];
	}
	else if ([parts[0] isEqualToString:@"!padtap2"]) {
		[self strokeFingers:2 dx:0 dy:0 hold:0.08 duration:0 after:0];
	}
	else if ([parts[0] isEqualToString:@"!padholddrag"]) {
		[self strokeFingers:1 dx:dx dy:dy hold:kDragHold + 0.1 duration:duration after:0];
	}
	else if ([parts[0] isEqualToString:@"!padtapdrag"]) {
		[self strokeFingers:1 dx:0 dy:0 hold:0.08 duration:0 after:0];
		[self strokeFingers:1 dx:dx dy:dy hold:0.05 duration:duration after:0.2];
	}
	else {
		return NO;
	}
	return YES;
}

@end
