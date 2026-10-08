/**
 * @file	extdisplay.m
 * @brief	The PC-98 screen on an external display (TV, monitor, AirPlay)
 *
 * The picture is taken from scrnmng.dispsurf (capture_screencgimage) on
 * every display refresh and set as a layer's contents; the emulator and
 * this run on the main thread.
 */

#include "compiler.h"
#include "extdisplay.h"
#include "capture.h"
#include "settings.h"
#include "scanlines.h"

#import <UIKit/UIKit.h>

NSNotificationName const NP2ExternalDisplayChanged = @"NP2ExternalDisplayChanged";

@interface NP2ExternalScreenController : UIViewController
@end

@interface NP2ExternalSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

static NSInteger s_connected;
static UIWindow *s_debugwindow;

BOOL extdisplay_isconnected(void)
{
	return s_connected > 0;
}

static void changed(NSInteger delta)
{
	s_connected += delta;
	[[NSNotificationCenter defaultCenter] postNotificationName:NP2ExternalDisplayChanged object:nil];
}

@implementation NP2ExternalScreenController {
	CADisplayLink *_link;
	UIView *_screen;
	NP2ScanlineView *_scanlines;
	CGSize _size;		/* of the PC-98 screen, in its pixels */
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.view.backgroundColor = UIColor.blackColor;
	_screen = [[UIView alloc] initWithFrame:CGRectZero];
	_screen.backgroundColor = UIColor.blackColor;
	[self.view addSubview:_screen];
	_scanlines = [[NP2ScanlineView alloc] initWithFrame:CGRectZero];
	[self.view addSubview:_scanlines];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applyStyle)
	                                             name:NSUserDefaultsDidChangeNotification object:nil];
	[self applyStyle];
}

- (void)viewWillAppear:(BOOL)animated
{
	[super viewWillAppear:animated];
	if (_link == nil) {
		_link = [CADisplayLink displayLinkWithTarget:self selector:@selector(refresh)];
		_link.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
		[_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
	}
}

- (void)viewDidDisappear:(BOOL)animated
{
	[super viewDidDisappear:animated];
	[_link invalidate];
	_link = nil;
}

- (void)applyStyle
{
	NSInteger style = settings_screenstyle();
	NSString *filter = (style == 0) ? kCAFilterNearest : kCAFilterLinear;
	_screen.layer.magnificationFilter = filter;
	_screen.layer.minificationFilter = kCAFilterLinear;
	_scanlines.hidden = (style != 2);
}

- (void)refresh
{
	CGImageRef image = capture_screencgimage();
	if (image == NULL) {
		return;
	}
	CGSize size = CGSizeMake(CGImageGetWidth(image), CGImageGetHeight(image));
	_screen.layer.contents = (__bridge id)image;
	CGImageRelease(image);
	if (!CGSizeEqualToSize(size, _size)) {
		_size = size;
		[self.view setNeedsLayout];
	}
}

/* As large as fits, keeping the PC-98 screen's shape (640x400 is 16:10). */
- (void)viewDidLayoutSubviews
{
	[super viewDidLayoutSubviews];
	CGSize bounds = self.view.bounds.size;
	CGSize size = (_size.width > 0) ? _size : CGSizeMake(640, 400);
	CGFloat scale = MIN(bounds.width / size.width, bounds.height / size.height);
	CGRect frame = CGRectMake((bounds.width - size.width * scale) / 2, (bounds.height - size.height * scale) / 2,
	                          size.width * scale, size.height * scale);
	_screen.frame = frame;
	_scanlines.frame = frame;
	[_scanlines setLines:size.height firstLineOffset:0];
}

@end

@implementation NP2ExternalSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions
{
	(void)session;
	(void)connectionOptions;
	if (![scene isKindOfClass:[UIWindowScene class]]) {
		return;
	}
	NSLog(@"extdisplay: connected (%@)", session.role);
	self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
	self.window.rootViewController = [NP2ExternalScreenController new];
	self.window.hidden = NO;
	changed(1);
}

- (void)sceneDidDisconnect:(UIScene *)scene
{
	(void)scene;
	NSLog(@"extdisplay: disconnected");
	self.window.hidden = YES;
	self.window = nil;
	changed(-1);
}

@end

void extdisplay_debugshow(BOOL show)
{
	if (show == (s_debugwindow != nil)) {
		return;
	}
	if (show) {
		UIWindowScene *scene = nil;
		for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
			if ([s isKindOfClass:[UIWindowScene class]] && [s.session.role isEqualToString:UIWindowSceneSessionRoleApplication]) {
				scene = (UIWindowScene *)s;
			}
		}
		s_debugwindow = [[UIWindow alloc] initWithWindowScene:scene];
		CGRect bounds = scene.coordinateSpace.bounds;
		s_debugwindow.frame = CGRectMake(0, bounds.size.height / 2, bounds.size.width, bounds.size.width * 9 / 16);
		s_debugwindow.windowLevel = UIWindowLevelAlert + 1;
		s_debugwindow.userInteractionEnabled = NO;
		s_debugwindow.rootViewController = [NP2ExternalScreenController new];
		s_debugwindow.hidden = NO;
		changed(1);
	}
	else {
		s_debugwindow.hidden = YES;
		s_debugwindow = nil;
		changed(-1);
	}
}
