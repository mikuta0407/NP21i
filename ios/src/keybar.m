/**
 * @file	keybar.m
 * @brief	On-screen bar with PC-98 keys and the app menu
 *
 * The PC-98 keys that iPad / iPhone keyboards lack (STOP, COPY, f.1-f.10,
 * vf.1-vf.5, HOME/CLR, HELP, ROLL UP/DOWN, GRPH, KANA, XFER, NFER, ...),
 * plus a menu for floppy and hard disk images, reset and the NP2 menu.
 * Disk images picked outside the data directory are copied into fdd/ or
 * hdd/; hard disk changes are saved to the config and apply at reset.
 *
 * The bar sits in the space the 16:10 screen leaves free (below it on iPad,
 * beside it on iPhone), over the screen when there is none, and above the
 * software keyboard while that is shown. It can be folded away.
 *
 * The keyboard button shows the keyboard chosen in the settings (long press
 * to choose): the app's own (kbdview.h, a PC-98 keyboard or another layout)
 * or iOS's. The app's own keyboard makes the PC-98 screen smaller to stay
 * above it.
 *
 * Runs on the main thread, which is also where the emulator runs (SDL pumps
 * the UIKit run loop from its event loop), so the core is called directly.
 */

#include "compiler.h"
#include "keybar.h"
#include "keyinput.h"
#include "dpad.h"
#include "kbdview.h"
#include "hinge.h"
#include "trackpad.h"
#include "gamepad.h"
#include "profile.h"
#include "capture.h"
#include "scanlines.h"
#include "midirec.h"
#include "lifecycle.h"
#include "settings.h"
#include "settingsview.h"
#include "diskedit.h"
#include "midiport.h"
#include "clipboard.h"

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <GameController/GameController.h>
#include "sdlcompat.h"
#include <pccore.h>
#include <nevent.h>
#include <fdd/diskdrv.h>
#include <fdd/sxsi.h>
#include <diskimage/fddfile.h>
#include <kbtrans.h>
#include <sysmenu.h>
#include <scrnmng.h>
#include <embed/vramhdl.h>
#include <embed/menubase/menubase.h>
#include <statsave.h>

enum {
	SCREEN_WIDTH	= 640,
	SCREEN_HEIGHT	= 400
};

static const CGFloat kMinBarHeight = 30;
static const CGFloat kMaxBarHeight = 50;
static const CGFloat kOverlayBarHeight = 40;
static const CGFloat kMinSideWidth = 44;
static const CGFloat kMaxSideWidth = 76;
static const CGFloat kGap = 4;
static const CGFloat kGroupGap = 12;

static NSString *const kHiddenKey = @"keybar_hidden";
static NSString *const kDPadPortraitKey = @"dpad_portrait";		/* below the bar, default on */
static NSString *const kDPadLandscapeKey = @"dpad_landscape";	/* over the screen, default off */
static NSString *const kFddDir = @"fdd";
static NSString *const kHddDir = @"hdd";

typedef NS_ENUM(NSInteger, KeyKind) {
	KeyKindKey,			/* down while touched */
	KeyKindModifier,	/* latches / toggles */
	KeyKindSeparator	/* not a button: extra space before the next one */
};

typedef struct {
	const char	*label;
	UINT8		code;
	KeyKind		kind;
} KEYDEF;

static const KEYDEF s_keys[] = {
	{"ESC", PC98KEY_ESC, KeyKindKey},
	{"STOP", PC98KEY_STOP, KeyKindKey},
	{"COPY", PC98KEY_COPY, KeyKindKey},
	{NULL, 0, KeyKindSeparator},
	{"f·1", PC98KEY_F1 + 0, KeyKindKey},
	{"f·2", PC98KEY_F1 + 1, KeyKindKey},
	{"f·3", PC98KEY_F1 + 2, KeyKindKey},
	{"f·4", PC98KEY_F1 + 3, KeyKindKey},
	{"f·5", PC98KEY_F1 + 4, KeyKindKey},
	{NULL, 0, KeyKindSeparator},
	{"f·6", PC98KEY_F1 + 5, KeyKindKey},
	{"f·7", PC98KEY_F1 + 6, KeyKindKey},
	{"f·8", PC98KEY_F1 + 7, KeyKindKey},
	{"f·9", PC98KEY_F1 + 8, KeyKindKey},
	{"f·10", PC98KEY_F1 + 9, KeyKindKey},
	{NULL, 0, KeyKindSeparator},
	{"SHIFT", PC98KEY_SHIFT, KeyKindModifier},
	{"CTRL", PC98KEY_CTRL, KeyKindModifier},
	{"GRPH", PC98KEY_GRPH, KeyKindModifier},
	{NULL, 0, KeyKindSeparator},
	{"HOME", PC98KEY_HOMECLR, KeyKindKey},
	{"HELP", PC98KEY_HELP, KeyKindKey},
	{"R UP", PC98KEY_ROLLUP, KeyKindKey},
	{"R DN", PC98KEY_ROLLDOWN, KeyKindKey},
	{"INS", PC98KEY_INS, KeyKindKey},
	{"DEL", PC98KEY_DEL, KeyKindKey},
	{NULL, 0, KeyKindSeparator},
	{"←", PC98KEY_LEFT, KeyKindKey},
	{"↑", PC98KEY_UP, KeyKindKey},
	{"↓", PC98KEY_DOWN, KeyKindKey},
	{"→", PC98KEY_RIGHT, KeyKindKey},
	{NULL, 0, KeyKindSeparator},
	{"XFER", PC98KEY_XFER, KeyKindKey},
	{"NFER", PC98KEY_NFER, KeyKindKey},
	{"CAPS", PC98KEY_CAPS, KeyKindModifier},
	{"カナ", PC98KEY_KANA, KeyKindModifier},
	{NULL, 0, KeyKindSeparator},
	{"vf·1", PC98KEY_VF1 + 0, KeyKindKey},
	{"vf·2", PC98KEY_VF1 + 1, KeyKindKey},
	{"vf·3", PC98KEY_VF1 + 2, KeyKindKey},
	{"vf·4", PC98KEY_VF1 + 3, KeyKindKey},
	{"vf·5", PC98KEY_VF1 + 4, KeyKindKey},
	{NULL, 0, KeyKindSeparator},
	{"TAB", PC98KEY_TAB, KeyKindKey},
	{"BS", PC98KEY_BS, KeyKindKey},
	{"RET", PC98KEY_RETURN, KeyKindKey},
};

// ---- core commands

static void reset_machine(void)
{
	sdlkbd_reset();
	pccore_cfgupdate();
	if (nevent_iswork(NEVENT_CDWAIT)) {
		nevent_forceexecute(NEVENT_CDWAIT);
	}
	pccore_reset();
}

static void insert_fdd(REG8 drive, NSString *path)
{
	diskdrv_setfdd(drive, path.fileSystemRepresentation, 0);
	NSLog(@"keybar: FDD%d <- %@", drive + 1, path);
}

static NSString *fdd_name(REG8 drive)
{
	const OEMCHAR *name = fdd_diskname(drive);
	if (name == NULL || name[0] == '\0') {
		return nil;
	}
	return [NSString stringWithUTF8String:name].lastPathComponent;
}

static const struct {
	REG8		drv;
	const char	*label;
} s_hddslots[] = {
	{0x00, "IDE #1"},
	{0x01, "IDE #2"},
	{0x20, "SCSI #0"},
	{0x21, "SCSI #1"},
	{0x22, "SCSI #2"},
	{0x23, "SCSI #3"},
};

static BOOL hdd_slot_available(REG8 drv)
{
	if (drv & 0x20) {
		return TRUE;
	}
	/* IDE slots can be set up as CD-ROM drives instead */
	return np2cfg.idetype[drv & 0x0f] == SXSIDEV_HDD;
}

static NSString *hdd_name(REG8 drv)
{
	const OEMCHAR *name = diskdrv_getsxsi(drv);
	if (name == NULL || name[0] == '\0') {
		return nil;
	}
	return [NSString stringWithUTF8String:name].lastPathComponent;
}

/* Saved to the config; the image is opened at the next reset. */
static void set_hdd(REG8 drv, NSString *path)
{
	diskdrv_setsxsi(drv, path ? path.fileSystemRepresentation : NULL);
	NSLog(@"keybar: HDD %02x <- %@", drv, path ?: @"(none)");
}

/* dir/name, or dir/name 2.ext ... if that exists (relative to dataDir) */
static NSString *unique_path(NSString *dir, NSString *name, NSString *dataDir)
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *path = [dir stringByAppendingPathComponent:name];
	NSString *base = name.stringByDeletingPathExtension;
	NSString *ext = name.pathExtension;
	for (int n = 2; [fm fileExistsAtPath:[dataDir stringByAppendingPathComponent:path]]; n++) {
		NSString *numbered = [NSString stringWithFormat:@"%@ %d", base, n];
		if (ext.length) {
			numbered = [numbered stringByAppendingPathExtension:ext];
		}
		path = [dir stringByAppendingPathComponent:numbered];
	}
	return path;
}

// ---- views

static __weak UITextField *s_textfield;	/* SDL's, behind the software keyboard */
static UIViewController *sdl_controller(void);
static void setup_text_field(UIViewController *controller);

@interface NP2KeyButton : UIButton
@property (nonatomic) UINT8 code;
@property (nonatomic) KeyKind kind;
@end

@implementation NP2KeyButton
@end

@interface NP2KeyBar : UIView <UIDocumentPickerDelegate, UIGestureRecognizerDelegate>
- (void)refreshModifiers;
- (UIViewController *)hostController;
- (void)pickFileInto:(NSString *)dir handler:(void (^)(NSString *path))handler;
- (void)setHdd:(REG8)drv path:(NSString *)path;
@end

/* How the screen and the app's keyboard share a half open iPhone Duo. */
typedef NS_ENUM(NSInteger, NP2Fold) {
	NP2FoldNone,		/* not folded, or no hinge */
	NP2FoldLaptop,		/* taller than wide: the screen above the hinge, the keyboard below */
	NP2FoldStacked,		/* wider than tall: the keyboard at the bottom as usual */
	NP2FoldScreenLeft,	/* wider than tall: the screen on the left half, the keyboard on the right */
	NP2FoldScreenRight	/* ... and the other way round */
};

@implementation NP2KeyBar {
	UIView *_bar;
	UIScrollView *_scroll;
	UIButton *_menuButton;
	UIButton *_softkbdButton;
	NP2KeyboardView *_screenKeyboard;	/* the app's own keyboard, nil until first shown */
	BOOL _screenKeyboardShown;
	NP2HingePosture _hinge;
	NP2Fold _fold;			/* folded: the keyboard takes part of the screen */
	BOOL _shownForFold;		/* the keyboard came up by itself when folded */
	UIButton *_dpadButton;
	NP2DPad *_dpad;
	NP2TrackpadView *_trackpad;	/* under everything, over SDL's view */
	NP2ScanlineView *_scanlines;	/* over the PC-98 screen (CRT look) */
	BOOL _pointerLocked;		/* a connected mouse moves the PC-98 mouse by travel */
	UIButton *_recordButton;	/* shown while recording (video, MIDI): stops it */
	CGRect _screenRect;			/* where the PC-98 screen is, unzoomed */
	CGFloat _pixelScale;		/* points per PC-98 pixel, unzoomed */
	CGFloat _zoom;				/* pinched in (1: all of the screen) */
	CGPoint _zoomCenter;		/* in PC-98 pixels */
	CGFloat _pinchStartZoom;
	BOOL _gesturesAdded;
	UIButton *_hideButton;
	UIButton *_showButton;
	UILabel *_speedLabel;
	CGSize _screenSize;		/* PC-98 screen size used for the last layout */
	int _slowCount;
	NSMutableArray<NP2KeyButton *> *_keys;
	NSMutableArray<NSNumber *> *_separatorBefore;	/* per key */
	CGRect _keyboardFrame;							/* software keyboard, in window coordinates */
	BOOL _softKeyboardShown;
	NSString *_pickDir;
	void (^_pickHandler)(NSString *path);
	BOOL _hidden;
}

- (instancetype)initWithFrame:(CGRect)frame
{
	self = [super initWithFrame:frame];
	if (!self) {
		return nil;
	}
	self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	_hidden = [[NSUserDefaults standardUserDefaults] boolForKey:kHiddenKey];
	_keyboardFrame = CGRectNull;

	_trackpad = [[NP2TrackpadView alloc] initWithFrame:CGRectZero];
	_trackpad.hidden = !settings_trackpad();
	_trackpad.speed = settings_trackpadspeed();
	[self addSubview:_trackpad];
	_scanlines = [[NP2ScanlineView alloc] initWithFrame:CGRectZero];
	[self addSubview:_scanlines];
	[self applyScreenStyle];

	_bar = [[UIView alloc] init];
	_bar.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.92];
	[self addSubview:_bar];

	_scroll = [[UIScrollView alloc] init];
	_scroll.showsHorizontalScrollIndicator = NO;
	_scroll.showsVerticalScrollIndicator = NO;
	[_bar addSubview:_scroll];

	_keys = [NSMutableArray array];
	_separatorBefore = [NSMutableArray array];
	BOOL separator = NO;
	for (size_t i = 0; i < NELEMENTS(s_keys); i++) {
		if (s_keys[i].kind == KeyKindSeparator) {
			separator = YES;
			continue;
		}
		NP2KeyButton *button = [self keyButton:&s_keys[i]];
		[_scroll addSubview:button];
		[_keys addObject:button];
		[_separatorBefore addObject:@(separator)];
		separator = NO;
	}

	_menuButton = [self symbolButton:@"line.3.horizontal" label:@"menu"];
	_menuButton.menu = [self makeMenu];
	_menuButton.showsMenuAsPrimaryAction = YES;
	[_bar addSubview:_menuButton];

	_softkbdButton = [self symbolButton:@"keyboard" label:@"softkbd"];
	[_softkbdButton addTarget:self action:@selector(toggleSoftKeyboard) forControlEvents:UIControlEventTouchUpInside];
	_softkbdButton.menu = [self keyboardMenu];		/* long press */
	[_bar addSubview:_softkbdButton];

	_dpadButton = [self symbolButton:@"dpad" label:@"dpad"];
	[_dpadButton addTarget:self action:@selector(toggleDPad) forControlEvents:UIControlEventTouchUpInside];
	[_bar addSubview:_dpadButton];

	[[NSUserDefaults standardUserDefaults] registerDefaults:@{ kDPadPortraitKey: @YES, kDPadLandscapeKey: @NO }];
	_dpad = [[NP2DPad alloc] initWithFrame:CGRectZero];
	[self addSubview:_dpad];

	_hideButton = [self symbolButton:@"chevron.down" label:@"hide"];
	[_hideButton addTarget:self action:@selector(hideBar) forControlEvents:UIControlEventTouchUpInside];
	[_bar addSubview:_hideButton];

	_showButton = [self symbolButton:@"keyboard.chevron.compact.down" label:@"show"];
	[_showButton setImage:[UIImage systemImageNamed:@"chevron.up"] forState:UIControlStateNormal];
	_showButton.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.6];
	[_showButton addTarget:self action:@selector(showBar) forControlEvents:UIControlEventTouchUpInside];
	[self addSubview:_showButton];

	_speedLabel = [[UILabel alloc] init];
	_speedLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
	_speedLabel.textColor = UIColor.blackColor;
	_speedLabel.textAlignment = NSTextAlignmentCenter;
	_speedLabel.backgroundColor = [UIColor.systemOrangeColor colorWithAlphaComponent:0.85];
	_speedLabel.layer.cornerRadius = 6;
	_speedLabel.layer.masksToBounds = YES;
	_speedLabel.hidden = YES;
	[self addSubview:_speedLabel];

	_zoom = 1;
	_recordButton = [UIButton buttonWithType:UIButtonTypeCustom];
	_recordButton.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold];
	[_recordButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
	_recordButton.backgroundColor = [UIColor.systemRedColor colorWithAlphaComponent:0.85];
	_recordButton.layer.cornerRadius = 6;
	_recordButton.hidden = YES;
	_recordButton.showsMenuAsPrimaryAction = YES;
	_recordButton.accessibilityIdentifier = @"recording";
	__weak NP2KeyBar *weakBar = self;
	_recordButton.menu = [UIMenu menuWithChildren:@[ [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
		completion([weakBar recordingStopItems]);
	}] ]];
	[self addSubview:_recordButton];

	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	[nc addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillChangeFrameNotification object:nil];
	[nc addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
	[nc addObserver:self selector:@selector(settingsChanged) name:NSUserDefaultsDidChangeNotification object:nil];

	/* CAPS / KANA also change from the hardware keyboard */
	__weak NP2KeyBar *weakSelf = self;
	[NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
		NP2KeyBar *bar = weakSelf;
		if (bar == nil) {
			[timer invalidate];
			return;
		}
		[bar refreshModifiers];
		[bar refreshSpeed];
		[bar checkScreenSize];
		[bar updatePointerLock];
		[bar refreshRecording];
	}];
	hinge_observe(self, ^(NP2HingePosture posture) {
		[weakSelf hingeChanged:posture];
	});
	[self applyHidden];
	return self;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
	/* Touches outside the bar go to the emulator screen (SDL's view). */
	UIView *hit = [super hitTest:point withEvent:event];
	return (hit == self) ? nil : hit;
}

- (NP2KeyButton *)keyButton:(const KEYDEF *)def
{
	NP2KeyButton *button = [NP2KeyButton buttonWithType:UIButtonTypeCustom];
	button.code = def->code;
	button.kind = def->kind;
	NSString *label = [NSString stringWithUTF8String:def->label];
	[button setTitle:label forState:UIControlStateNormal];
	[button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
	button.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
	button.titleLabel.adjustsFontSizeToFitWidth = YES;
	button.titleLabel.minimumScaleFactor = 0.7;
	button.backgroundColor = [UIColor colorWithWhite:0.30 alpha:1];
	button.layer.cornerRadius = 5;
	button.accessibilityIdentifier = label;
	if (def->kind == KeyKindModifier) {
		[button addTarget:self action:@selector(modifierTapped:) forControlEvents:UIControlEventTouchDown];
	}
	else {
		[button addTarget:self action:@selector(keyDown:) forControlEvents:UIControlEventTouchDown];
		[button addTarget:self action:@selector(keyUp:)
		 forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
	}
	return button;
}

- (UIButton *)symbolButton:(NSString *)symbol label:(NSString *)label
{
	UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
	[button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
	button.tintColor = UIColor.whiteColor;
	button.layer.cornerRadius = 5;
	button.accessibilityIdentifier = label;
	return button;
}

// ---- keys

- (void)keyDown:(NP2KeyButton *)button
{
	button.backgroundColor = [UIColor colorWithWhite:0.55 alpha:1];
	keyinput_down(button.code);
}

- (void)keyUp:(NP2KeyButton *)button
{
	button.backgroundColor = [UIColor colorWithWhite:0.30 alpha:1];
	keyinput_up(button.code);
	[self refreshModifiers];
}

- (void)modifierTapped:(NP2KeyButton *)button
{
	keyinput_togglemodifier(button.code);
	[self refreshModifiers];
}

- (void)refreshModifiers
{
	[_screenKeyboard refreshStates];
	for (NP2KeyButton *button in _keys) {
		if (button.kind == KeyKindModifier) {
			button.backgroundColor = keyinput_isactive(button.code)
				? UIColor.systemOrangeColor : [UIColor colorWithWhite:0.30 alpha:1];
		}
	}
}

/* The guest can switch to 640x480 etc. */
- (void)checkScreenSize
{
	int w = 0, h = 0;
	scrnmng_getsize(&w, &h);
	if (w != (int)_screenSize.width || h != (int)_screenSize.height) {
		[self setNeedsLayout];
	}
}

/* Warns when the emulator cannot keep real time (MIDI timing suffers). */
- (void)refreshSpeed
{
	double speed = lifecycle_emulationspeed();
	if (speed < 0) {
		return;		/* no new measurement yet */
	}
	_slowCount = (speed < 0.95) ? _slowCount + 1 : 0;
	BOOL show = settings_showspeed() && _slowCount >= 2;
	if (show) {
		_speedLabel.text = [NSString stringWithFormat:@"速度 %d%%", (int)(speed * 100 + 0.5)];
	}
	if (_speedLabel.hidden == show) {
		_speedLabel.hidden = !show;
		[self setNeedsLayout];
	}
}

- (BOOL)isPortrait
{
	return self.bounds.size.height > self.bounds.size.width;
}

/* Portrait and landscape remember their own choice: the cross keys have
 * room of their own below the bar in portrait, but cover the screen in
 * landscape. */
- (NSString *)dpadKey
{
	return [self isPortrait] ? kDPadPortraitKey : kDPadLandscapeKey;
}

- (void)toggleDPad
{
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	[defaults setBool:![defaults boolForKey:[self dpadKey]] forKey:[self dpadKey]];
	[self setNeedsLayout];
}

/* A mouse connected to an iPad drives the PC-98 mouse by how far it moves,
 * its pointer locked in the app (SDL's relative mode), unless turned off in
 * the settings. Not while the NP2 menu, which is pointed at, or another
 * screen (settings, disks) is up, or the app is not in front. */
- (void)updatePointerLock
{
	BOOL lock = NO;
	if (@available(iOS 14.0, *)) {
		lock = settings_mouselock() && GCMouse.mice.count > 0 && menuvram == NULL
			&& self.window.rootViewController.presentedViewController == nil
			&& UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
	}
	if (lock != _pointerLocked) {
		_pointerLocked = lock;
		np21_setrelativemouse(lock);
		NSLog(@"keybar: pointer %s", lock ? "locked" : "unlocked");
	}
}

// ---- recording (video, MIDI)

- (void)refreshRecording
{
	NSMutableArray<NSString *> *parts = [NSMutableArray array];
	if (capture_isrecording()) {
		[parts addObject:@"● 録画"];
	}
	if (midirec_isrecording()) {
		NSTimeInterval t = midirec_duration();
		[parts addObject:[NSString stringWithFormat:@"● MIDI %d:%02d", (int)t / 60, (int)t % 60]];
	}
	BOOL show = parts.count > 0;
	if (show) {
		[_recordButton setTitle:[parts componentsJoinedByString:@"  "] forState:UIControlStateNormal];
	}
	if (_recordButton.hidden == show) {
		_recordButton.hidden = !show;
		[self setNeedsLayout];
	}
	else if (show) {
		[self setNeedsLayout];
	}
}

- (void)layoutRecordButtonAt:(CGPoint)origin
{
	CGSize size = [_recordButton.titleLabel sizeThatFits:CGSizeMake(300, 22)];
	_recordButton.frame = CGRectMake(origin.x, origin.y, ceil(size.width) + 16, 22);
}

- (NSArray<UIMenuElement *> *)recordingStopItems
{
	__weak NP2KeyBar *weakSelf = self;
	NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
	if (capture_isrecording()) {
		[items addObject:[UIAction actionWithTitle:@"録画を止める" image:[UIImage systemImageNamed:@"stop.circle"] identifier:nil handler:^(UIAction *a) {
			(void)a;
			capture_stoprecording([weakSelf hostController]);
			[weakSelf refreshRecording];
		}]];
	}
	if (midirec_isrecording()) {
		[items addObject:[UIAction actionWithTitle:@"MIDI の記録を止める" image:[UIImage systemImageNamed:@"stop.circle"] identifier:nil handler:^(UIAction *a) {
			(void)a;
			midirec_stop([weakSelf hostController]);
			[weakSelf refreshRecording];
		}]];
	}
	return items;
}

- (UIMenu *)captureMenu
{
	__weak NP2KeyBar *weakSelf = self;
	NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
	[items addObject:[UIAction actionWithTitle:@"スクリーンショット" image:[UIImage systemImageNamed:@"camera"] identifier:nil handler:^(UIAction *a) {
		(void)a;
		capture_screenshot([weakSelf hostController]);
	}]];
	if (capture_isrecording()) {
		[items addObject:[UIAction actionWithTitle:@"録画を止める" image:[UIImage systemImageNamed:@"stop.circle"] identifier:nil handler:^(UIAction *a) {
			(void)a;
			capture_stoprecording([weakSelf hostController]);
			[weakSelf refreshRecording];
		}]];
	}
	else {
		[items addObject:[UIAction actionWithTitle:@"画面を録画" image:[UIImage systemImageNamed:@"record.circle"] identifier:nil handler:^(UIAction *a) {
			(void)a;
			capture_startrecording();
			[weakSelf refreshRecording];
		}]];
	}
	if (midirec_isrecording()) {
		[items addObject:[UIAction actionWithTitle:@"MIDI の記録を止める" image:[UIImage systemImageNamed:@"stop.circle"] identifier:nil handler:^(UIAction *a) {
			(void)a;
			midirec_stop([weakSelf hostController]);
			[weakSelf refreshRecording];
		}]];
	}
	else {
		[items addObject:[UIAction actionWithTitle:@"MIDI を記録" image:[UIImage systemImageNamed:@"pianokeys"] identifier:nil handler:^(UIAction *a) {
			(void)a;
			midirec_start();
			[weakSelf refreshRecording];
		}]];
	}
	return [UIMenu menuWithTitle:@"記録" image:[UIImage systemImageNamed:@"camera"] identifier:nil options:0 children:items];
}

// ---- state slots

static UIImage *slot_thumbnail(NSInteger slot)
{
	NSString *path = profile_slotimagepath(slot);
	UIImage *image = path ? [UIImage imageWithContentsOfFile:path] : nil;
	if (image == nil) {
		return [UIImage systemImageNamed:@"square.dashed"];
	}
	CGSize size = CGSizeMake(48, 30);
	UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
	return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
		[image drawInRect:CGRectMake(0, 0, size.width, size.height)];
	}];
}

- (UIMenu *)slotsMenu
{
	__weak NP2KeyBar *weakSelf = self;
	NSDateFormatter *format = [NSDateFormatter new];
	format.dateFormat = @"M/d H:mm";
	NSMutableArray<UIMenuElement *> *slots = [NSMutableArray array];
	for (NSInteger slot = 0; slot < PROFILE_SLOTS; slot++) {
		NSDate *date = profile_slotdate(slot);
		NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
		[actions addObject:[UIAction actionWithTitle:@"ここに保存" image:[UIImage systemImageNamed:@"square.and.arrow.down"] identifier:nil handler:^(UIAction *a) {
			(void)a;
			[weakSelf saveSlot:slot];
		}]];
		if (date) {
			[actions addObject:[UIAction actionWithTitle:@"ここに戻る" image:[UIImage systemImageNamed:@"arrow.uturn.backward"] identifier:nil handler:^(UIAction *a) {
				(void)a;
				[weakSelf confirmLoadSlot:slot];
			}]];
			UIAction *remove = [UIAction actionWithTitle:@"削除" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *a) {
				(void)a;
				profile_deleteslot(slot);
			}];
			remove.attributes = UIMenuElementAttributesDestructive;
			[actions addObject:remove];
		}
		UIMenu *menu = [UIMenu menuWithTitle:[NSString stringWithFormat:@"スロット %ld", (long)slot + 1] image:slot_thumbnail(slot)
		                          identifier:nil options:0 children:actions];
		menu.subtitle = date ? [format stringFromDate:date] : @"空き";
		[slots addObject:menu];
	}
	UIMenu *menu = [UIMenu menuWithTitle:@"状態の保存と読み込み" image:[UIImage systemImageNamed:@"clock.arrow.circlepath"]
	                          identifier:nil options:0 children:slots];
	menu.subtitle = profile_name(profile_active());
	return menu;
}

- (void)saveSlot:(NSInteger)slot
{
	if (!profile_saveslot(slot)) {
		[self showMessage:@"保存できませんでした" detail:nil];
	}
}

- (void)confirmLoadSlot:(NSInteger)slot
{
	int check = profile_checkslot(slot);
	if (check == STATFLAG_FAILURE || (check & STATFLAG_VERSION)) {
		[self showMessage:@"読み込めません" detail:@"このスロットの状態は、今のバージョンのアプリとは合いません。"];
		return;
	}
	BOOL changed = (check & STATFLAG_DISKCHG) != 0;
	NSString *message = changed
		? @"保存したあとにディスクイメージが変わっています。戻ると、そのディスクの中身が壊れることがあります（ハードディスクの変更は失われます）。"
		: @"今の状態は失われます。";
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"スロット %ld に戻りますか？", (long)slot + 1]
	                                                               message:message preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
	[alert addAction:[UIAlertAction actionWithTitle:@"戻る" style:changed ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
		(void)a;
		profile_loadslot(slot);
	}]];
	[[self hostController] presentViewController:alert animated:YES completion:nil];
}

- (void)showMessage:(NSString *)title detail:(NSString *)detail
{
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:detail preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	[[self hostController] presentViewController:alert animated:YES completion:nil];
}

// ---- zoom (two fingers on the screen)

- (void)setScreenRect:(CGRect)rect scale:(CGFloat)scale
{
	_screenRect = rect;
	_pixelScale = scale;
	_trackpad.pointsPerPixel = scale * _zoom;
	[self updateScanlines];
}

/* Sharp pixels, smoothed, or smoothed with scan lines (settings). */
- (void)applyScreenStyle
{
	NSInteger style = settings_screenstyle();
	scrnmng_setsmooth(style != 0);
	_scanlines.hidden = (style != 2);
}

- (void)updateScanlines
{
	_scanlines.frame = _screenRect;
	CGFloat lines = _screenSize.height / MAX(_zoom, 1);
	CGFloat top = MIN(MAX(_zoomCenter.y - lines / 2, 0), _screenSize.height - lines);
	[_scanlines setLines:lines firstLineOffset:(_zoom > 1) ? top - floor(top) : 0];
}

- (void)setZoom:(CGFloat)zoom center:(CGPoint)center
{
	CGSize screen = _screenSize;
	if (zoom < 1.05 || screen.width <= 0) {
		zoom = 1;
		center = CGPointMake(screen.width / 2, screen.height / 2);
	}
	zoom = MIN(zoom, 6);
	CGFloat halfW = screen.width / zoom / 2, halfH = screen.height / zoom / 2;
	center.x = MIN(MAX(center.x, halfW), screen.width - halfW);
	center.y = MIN(MAX(center.y, halfH), screen.height - halfH);
	_zoom = zoom;
	_zoomCenter = center;
	scrnmng_setzoom((float)zoom, (float)center.x, (float)center.y);
	_trackpad.pointsPerPixel = _pixelScale * _zoom;
	[self updateScanlines];
}

/* The PC-98 pixel at a point of the screen now, and where along it that is. */
- (CGPoint)pixelAt:(CGPoint)point fraction:(CGPoint *)fraction
{
	CGPoint f = CGPointMake((point.x - _screenRect.origin.x) / MAX(_screenRect.size.width, 1),
		(point.y - _screenRect.origin.y) / MAX(_screenRect.size.height, 1));
	if (fraction) {
		*fraction = f;
	}
	CGFloat w = _screenSize.width / _zoom, h = _screenSize.height / _zoom;
	return CGPointMake(_zoomCenter.x - w / 2 + f.x * w, _zoomCenter.y - h / 2 + f.y * h);
}

- (void)pinched:(UIPinchGestureRecognizer *)pinch
{
	if (pinch.state == UIGestureRecognizerStateBegan) {
		_pinchStartZoom = _zoom;
		if (_zoom <= 1) {
			_zoomCenter = CGPointMake(_screenSize.width / 2, _screenSize.height / 2);
		}
	}
	if (pinch.numberOfTouches < 2 && pinch.state == UIGestureRecognizerStateChanged) {
		return;
	}
	/* the pixel between the fingers stays there */
	CGPoint fraction;
	CGPoint pixel = [self pixelAt:[pinch locationInView:self] fraction:&fraction];
	CGFloat zoom = MAX(_pinchStartZoom * pinch.scale, 1);
	CGFloat w = _screenSize.width / zoom, h = _screenSize.height / zoom;
	[self setZoom:zoom center:CGPointMake(pixel.x - fraction.x * w + w / 2, pixel.y - fraction.y * h + h / 2)];
}

- (void)panned:(UIPanGestureRecognizer *)pan
{
	CGPoint t = [pan translationInView:self];
	[pan setTranslation:CGPointZero inView:self];
	CGFloat perPoint = 1 / MAX(_pixelScale * _zoom, 0.01);
	[self setZoom:_zoom center:CGPointMake(_zoomCenter.x - t.x * perPoint, _zoomCenter.y - t.y * perPoint)];
}

- (void)didMoveToSuperview
{
	[super didMoveToSuperview];
	if (self.superview && !_gesturesAdded) {
		_gesturesAdded = YES;
		/* on SDL's view, which gets the touches on the screen (or the
		 * trackpad, a subview of this) */
		UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:self action:@selector(pinched:)];
		pinch.delegate = self;
		[self.superview addGestureRecognizer:pinch];
		UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panned:)];
		pan.minimumNumberOfTouches = 2;
		pan.maximumNumberOfTouches = 2;
		pan.delegate = self;
		[self.superview addGestureRecognizer:pan];
	}
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldReceiveTouch:(UITouch *)touch
{
	if (!settings_pinchzoom() || menuvram != NULL) {
		return NO;
	}
	/* only on the screen: not the bar, keyboard or cross keys */
	UIView *hit = [self hitTest:[touch locationInView:self] withEvent:nil];
	return hit == nil || hit == _trackpad;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer
{
	if ([recognizer isKindOfClass:[UIPanGestureRecognizer class]]) {
		return _zoom > 1;
	}
	return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other
{
	return YES;
}

- (void)hingeChanged:(NP2HingePosture)posture
{
	if (posture != _hinge) {
		_hinge = posture;
		[self setNeedsLayout];
	}
}

/* Folded (half open), the app's keyboard comes up by itself: like a laptop
 * (taller than wide) in the lower half; held like a book (wider than tall)
 * as the settings say, at the bottom or in one half. It goes again when the
 * device is opened, unless it was shown or hidden by hand meanwhile. With
 * iOS's keyboard chosen in the settings, folding changes nothing. */
- (void)updateFold
{
	NP2Fold fold = NP2FoldNone;
	if (_hinge == NP2HingePosturePartiallyOpen) {
		if ([self isPortrait]) {
			fold = NP2FoldLaptop;
		}
		else {
			switch (settings_landscapefold()) {
				case 1:
					fold = NP2FoldScreenLeft;
					break;
				case 2:
					fold = NP2FoldScreenRight;
					break;
				default:
					fold = NP2FoldStacked;
					break;
			}
		}
	}
	BOOL folded = (fold != NP2FoldNone);
	BOOL wasFolded = (_fold != NP2FoldNone);
	_fold = fold;
	if (folded == wasFolded) {
		return;
	}
	if (folded) {
		if (!_screenKeyboardShown && [NP2KeyboardLayout layoutWithIdentifier:settings_screenkeyboard()] != nil) {
			[self showKeyboard];
			_shownForFold = YES;
		}
	}
	else if (_shownForFold) {
		_shownForFold = NO;
		[self hideKeyboards];
	}
}

- (void)toggleSoftKeyboard
{
	_shownForFold = NO;
	/* with a hardware keyboard, iOS shows only a thin shortcut bar */
	BOOL systemShown = _softKeyboardShown && CGRectGetHeight(_keyboardFrame) > 150;
	if (_screenKeyboardShown || systemShown) {
		[self hideKeyboards];
	}
	else {
		[self showKeyboard];
	}
}

- (void)showKeyboard
{
	NP2KeyboardLayout *layout = [NP2KeyboardLayout layoutWithIdentifier:settings_screenkeyboard()];
	if (layout == nil) {
		[self setScreenKeyboardShown:NO];
		[self showSystemKeyboard];
		return;
	}
	if (_softKeyboardShown) {
		np21_stoptextinput();
	}
	if (_screenKeyboard == nil) {
		_screenKeyboard = [[NP2KeyboardView alloc] initWithLayout:layout];
		[self addSubview:_screenKeyboard];
		[self bringSubviewToFront:_bar];
	}
	_screenKeyboard.layout = layout;
	_screenKeyboard.hapticFeedback = settings_keyhaptics();
	_screenKeyboard.keyPreview = settings_keypreview();
	[self setScreenKeyboardShown:YES];
}

- (void)hideKeyboards
{
	[self setScreenKeyboardShown:NO];
	/* SDL enables text input from the start without showing the keyboard,
	 * so look at the keyboard itself. */
	if (_softKeyboardShown) {
		np21_stoptextinput();
	}
}

- (void)showSystemKeyboard
{
	np21_starttextinput();
	/* SDL3 sets the text input traits again on every start */
	setup_text_field(sdl_controller());
	[s_textfield reloadInputViews];
}

- (void)setScreenKeyboardShown:(BOOL)shown
{
	if (shown != _screenKeyboardShown) {
		_screenKeyboardShown = shown;
		_screenKeyboard.hidden = !shown;
		[self setNeedsLayout];
	}
}

/* The keyboard button's long press: which keyboard it shows. */
- (UIMenu *)keyboardMenu
{
	__weak NP2KeyBar *weakSelf = self;
	UIDeferredMenuElement *choices = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
		NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
		NSString *current = settings_screenkeyboard();
		for (NSString *identifier in settings_screenkeyboards()) {
			UIAction *action = [UIAction actionWithTitle:settings_screenkeyboardtitle(identifier) image:nil identifier:nil handler:^(UIAction *a) {
				(void)a;
				[weakSelf chooseKeyboard:identifier];
			}];
			action.state = [identifier isEqualToString:current] ? UIMenuElementStateOn : UIMenuElementStateOff;
			[items addObject:action];
		}
		completion(items);
	}];
	return [UIMenu menuWithTitle:@"画面のキーボード" children:@[ choices ]];
}

- (void)chooseKeyboard:(NSString *)identifier
{
	[[NSUserDefaults standardUserDefaults] setObject:identifier forKey:kSettingScreenKeyboard];
	_shownForFold = NO;
	[self hideKeyboards];
	[self showKeyboard];
}

/* The settings screen can change the keyboard while one is shown. */
- (void)settingsChanged
{
	_trackpad.hidden = !settings_trackpad();
	_trackpad.speed = settings_trackpadspeed();
	[self setNeedsLayout];		/* the layout when folded */
	[self applyScreenStyle];
	_screenKeyboard.hapticFeedback = settings_keyhaptics();
	_screenKeyboard.keyPreview = settings_keypreview();
	if (!settings_pinchzoom() && _zoom > 1) {
		[self setZoom:1 center:CGPointZero];
	}
	if (_screenKeyboardShown) {
		NP2KeyboardLayout *layout = [NP2KeyboardLayout layoutWithIdentifier:settings_screenkeyboard()];
		if (layout == nil) {
			[self setScreenKeyboardShown:NO];
		}
		else if (layout != _screenKeyboard.layout) {
			_screenKeyboard.layout = layout;
			[self setNeedsLayout];
		}
	}
}

// ---- menu

- (UIMenu *)makeMenu
{
	__weak NP2KeyBar *weakSelf = self;
	UIDeferredMenuElement *fdd = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
		NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
		for (REG8 drive = 0; drive < 2; drive++) {
			NSString *name = fdd_name(drive);
			UIAction *insert = [UIAction actionWithTitle:[NSString stringWithFormat:@"FDD%d にディスクを入れる…", drive + 1]
			                                       image:[UIImage systemImageNamed:@"opticaldiscdrive"]
			                                  identifier:nil
			                                     handler:^(UIAction *action) {
				(void)action;
				[weakSelf pickFileInto:kFddDir handler:^(NSString *path) {
					insert_fdd(drive, path);
				}];
			}];
			insert.subtitle = name ?: @"空";
			[items addObject:insert];
			if (name) {
				UIAction *eject = [UIAction actionWithTitle:[NSString stringWithFormat:@"FDD%d を取り出す", drive + 1]
				                                      image:[UIImage systemImageNamed:@"eject"]
				                                 identifier:nil
				                                    handler:^(UIAction *action) {
					(void)action;
					diskdrv_setfdd(drive, NULL, 0);
				}];
				[items addObject:eject];
			}
		}
		completion(items);
	}];
	UIDeferredMenuElement *hdd = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
		completion(@[ [weakSelf hddMenu] ]);
	}];
	UIAction *reset = [UIAction actionWithTitle:@"リセット" image:[UIImage systemImageNamed:@"arrow.counterclockwise"]
	                                identifier:nil handler:^(UIAction *action) {
		(void)action;
		[weakSelf confirmReset];
	}];
	reset.attributes = UIMenuElementAttributesDestructive;
	UIDeferredMenuElement *profiles = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
		NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
		for (NSString *identifier in profile_ids()) {
			UIAction *action = [UIAction actionWithTitle:profile_name(identifier) image:nil identifier:nil handler:^(UIAction *a) {
				(void)a;
				settingsview_switchprofile([weakSelf hostController], identifier);
			}];
			action.state = [identifier isEqualToString:profile_active()] ? UIMenuElementStateOn : UIMenuElementStateOff;
			[items addObject:action];
		}
		[items addObject:[UIAction actionWithTitle:@"環境の管理…" image:[UIImage systemImageNamed:@"square.stack.3d.up"]
		                                identifier:nil handler:^(UIAction *a) {
			(void)a;
			settingsview_presentprofiles([weakSelf hostController]);
		}]];
		UIMenu *menu = [UIMenu menuWithTitle:@"環境" image:[UIImage systemImageNamed:@"square.stack.3d.up"]
		                          identifier:nil options:0 children:items];
		menu.subtitle = profile_name(profile_active());
		completion(@[ menu ]);
	}];
	UIDeferredMenuElement *slots = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
		completion(@[ [weakSelf slotsMenu] ]);
	}];
	UIDeferredMenuElement *capture = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
		NP2KeyBar *bar = weakSelf;
		NSMutableArray<UIMenuElement *> *items = [NSMutableArray arrayWithObject:[bar captureMenu]];
		if (bar && bar->_zoom > 1) {
			[items addObject:[UIAction actionWithTitle:@"拡大を戻す" image:[UIImage systemImageNamed:@"arrow.down.right.and.arrow.up.left"]
			                                identifier:nil handler:^(UIAction *a) {
				(void)a;
				[weakSelf setZoom:1 center:CGPointZero];
			}]];
		}
		completion(items);
	}];
	UIDeferredMenuElement *trackpad = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
		UIAction *action = [UIAction actionWithTitle:@"画面をタッチパッドにする" image:[UIImage systemImageNamed:@"rectangle.and.hand.point.up.left"]
		                                  identifier:nil handler:^(UIAction *a) {
			(void)a;
			[[NSUserDefaults standardUserDefaults] setBool:!settings_trackpad() forKey:kSettingTrackpad];
		}];
		action.state = settings_trackpad() ? UIMenuElementStateOn : UIMenuElementStateOff;
		completion(@[ action ]);
	}];
	UIDeferredMenuElement *clipboard = [UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
		NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
		[items addObject:[UIAction actionWithTitle:@"画面の文字をコピー" image:[UIImage systemImageNamed:@"doc.on.doc"]
		                                identifier:nil handler:^(UIAction *a) {
			(void)a;
			clipboard_copyscreen();
		}]];
		[items addObject:[UIAction actionWithTitle:@"画面の文字を選んでコピー…" image:[UIImage systemImageNamed:@"text.viewfinder"]
		                                identifier:nil handler:^(UIAction *a) {
			(void)a;
			clipboard_presentscreen([weakSelf hostController]);
		}]];
		if (clipboard_istyping()) {
			UIAction *stop = [UIAction actionWithTitle:@"貼り付けを止める" image:[UIImage systemImageNamed:@"stop.circle"]
			                                identifier:nil handler:^(UIAction *a) {
				(void)a;
				clipboard_stoptyping();
			}];
			stop.attributes = UIMenuElementAttributesDestructive;
			[items addObject:stop];
		}
		else {
			UIAction *paste = [UIAction actionWithTitle:@"貼り付け（キー入力）" image:[UIImage systemImageNamed:@"doc.on.clipboard"]
			                                 identifier:nil handler:^(UIAction *a) {
				(void)a;
				clipboard_paste([weakSelf hostController]);
			}];
			paste.subtitle = @"英数字とカナを 1 文字ずつ打ちます";
			[items addObject:paste];
		}
		UIMenu *menu = [UIMenu menuWithTitle:@"コピー・貼り付け" image:[UIImage systemImageNamed:@"doc.on.clipboard"]
		                          identifier:nil options:0 children:items];
		completion(@[ menu ]);
	}];
	UIAction *settings = [UIAction actionWithTitle:@"設定…" image:[UIImage systemImageNamed:@"gearshape"]
	                                   identifier:nil handler:^(UIAction *action) {
		(void)action;
		settingsview_present([weakSelf hostController]);
	}];
	UIAction *help = [UIAction actionWithTitle:@"使い方…" image:[UIImage systemImageNamed:@"questionmark.circle"]
	                               identifier:nil handler:^(UIAction *action) {
		(void)action;
		settingsview_presenthelp([weakSelf hostController]);
	}];
	UIAction *np2menu = [UIAction actionWithTitle:@"NP2 メニュー (F11)" image:[UIImage systemImageNamed:@"slider.horizontal.3"]
	                                  identifier:nil handler:^(UIAction *action) {
		(void)action;
		sysmenu_menuopen(0, 0, 0);
	}];
	UIAction *files = [UIAction actionWithTitle:@"ディスクの中身…" image:[UIImage systemImageNamed:@"folder"]
	                                identifier:nil handler:^(UIAction *action) {
		(void)action;
		diskedit_present([weakSelf hostController]);
	}];
	return [UIMenu menuWithChildren:@[
		[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[ profiles, slots, fdd, hdd, files ]],
		[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[ capture, clipboard, trackpad ]],
		[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[ settings, help, np2menu, reset ]],
	]];
}

/* One submenu per HDD slot: choose an image or remove it. Changes are
 * written to the config and take effect at the next reset. */
- (UIMenu *)hddMenu
{
	__weak NP2KeyBar *weakSelf = self;
	NSMutableArray<UIMenuElement *> *slots = [NSMutableArray array];
	for (size_t i = 0; i < NELEMENTS(s_hddslots); i++) {
		REG8 drv = s_hddslots[i].drv;
		if (!hdd_slot_available(drv)) {
			continue;
		}
		NSString *name = hdd_name(drv);
		NSString *label = [NSString stringWithUTF8String:s_hddslots[i].label];
		NSMutableArray<UIMenuElement *> *actions = [NSMutableArray array];
		[actions addObject:[UIAction actionWithTitle:@"イメージを選ぶ…" image:[UIImage systemImageNamed:@"folder"]
		                                  identifier:nil handler:^(UIAction *action) {
			(void)action;
			[weakSelf pickFileInto:kHddDir handler:^(NSString *path) {
				[weakSelf setHdd:drv path:path];
			}];
		}]];
		if (name) {
			UIAction *remove = [UIAction actionWithTitle:@"外す" image:[UIImage systemImageNamed:@"eject"]
			                                  identifier:nil handler:^(UIAction *action) {
				(void)action;
				[weakSelf setHdd:drv path:nil];
			}];
			remove.attributes = UIMenuElementAttributesDestructive;
			[actions addObject:remove];
		}
		UIMenu *slot = [UIMenu menuWithTitle:label image:nil identifier:nil options:0 children:actions];
		slot.subtitle = name ?: @"なし";
		[slots addObject:slot];
	}
	UIMenu *menu = [UIMenu menuWithTitle:@"ハードディスク" image:[UIImage systemImageNamed:@"internaldrive"]
	                          identifier:nil options:0 children:slots];
	menu.subtitle = @"リセット後に反映";
	return menu;
}

- (void)setHdd:(REG8)drv path:(NSString *)path
{
	set_hdd(drv, path);
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"ハードディスクを変更しました"
	                                                               message:@"リセットすると反映されます。今すぐリセットしますか？保存していないデータは失われます。"
	                                                        preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"あとで" style:UIAlertActionStyleCancel handler:nil]];
	[alert addAction:[UIAlertAction actionWithTitle:@"リセット" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
		(void)action;
		reset_machine();
	}]];
	[[self hostController] presentViewController:alert animated:YES completion:nil];
}

/* The topmost presented controller (e.g. the settings screen), to present on. */
- (UIViewController *)hostController
{
	UIResponder *responder = self;
	while (responder && ![responder isKindOfClass:[UIViewController class]]) {
		responder = responder.nextResponder;
	}
	UIViewController *controller = (UIViewController *)responder;
	while (controller.presentedViewController && !controller.presentedViewController.isBeingDismissed) {
		controller = controller.presentedViewController;
	}
	return controller;
}

- (void)confirmReset
{
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"リセットしますか？"
	                                                               message:@"保存していないデータは失われます。"
	                                                        preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
	[alert addAction:[UIAlertAction actionWithTitle:@"リセット" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
		(void)action;
		reset_machine();
	}]];
	[[self hostController] presentViewController:alert animated:YES completion:nil];
}

- (void)showError:(NSString *)message
{
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"ディスクを読み込めません"
	                                                               message:message
	                                                        preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	[[self hostController] presentViewController:alert animated:YES completion:nil];
}

/* Lets the user pick a disk image in the Files app. The handler gets a path
 * relative to the data directory (the current directory). */
- (void)pickFileInto:(NSString *)dir handler:(void (^)(NSString *path))handler
{
	_pickDir = dir;
	_pickHandler = handler;
	UIDocumentPickerViewController *picker =
		[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeData ] asCopy:NO];
	picker.delegate = self;
	picker.directoryURL = [NSURL fileURLWithPath:[[NSFileManager defaultManager] currentDirectoryPath] isDirectory:YES];
	[[self hostController] presentViewController:picker animated:YES completion:nil];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller
{
	(void)controller;
	_pickHandler = nil;
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
	(void)controller;
	NSURL *url = urls.firstObject;
	void (^handler)(NSString *) = _pickHandler;
	_pickHandler = nil;
	if (url == nil || handler == nil) {
		return;
	}

	/* Files inside the app's data directory are used in place. */
	NSString *dataDir = [[NSFileManager defaultManager].currentDirectoryPath stringByResolvingSymlinksInPath];
	NSString *picked = [url.path stringByResolvingSymlinksInPath];
	if ([picked hasPrefix:[dataDir stringByAppendingString:@"/"]]) {
		handler([picked substringFromIndex:dataDir.length + 1]);
		return;
	}
	[self importURL:url into:_pickDir handler:handler];
}

/* Others (iCloud, other apps) are copied into dir/ so that they stay usable
 * and writable. Hard disk images can be large, so this runs in the
 * background behind a progress alert. An existing file is never replaced. */
- (void)importURL:(NSURL *)url into:(NSString *)dir handler:(void (^)(NSString *path))handler
{
	UIAlertController *progress = [UIAlertController alertControllerWithTitle:@"コピーしています…"
	                                                                  message:url.lastPathComponent
	                                                           preferredStyle:UIAlertControllerStyleAlert];
	[[self hostController] presentViewController:progress animated:YES completion:nil];

	NSString *dataDir = [NSFileManager defaultManager].currentDirectoryPath;
	__weak NP2KeyBar *weakSelf = self;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSFileManager *fm = [NSFileManager defaultManager];
		NSString *dest = unique_path(dir, url.lastPathComponent, dataDir);
		[fm createDirectoryAtPath:[dataDir stringByAppendingPathComponent:dir] withIntermediateDirectories:YES attributes:nil error:nil];

		BOOL scoped = [url startAccessingSecurityScopedResource];
		__block NSError *error = nil;
		NSError *coordinateError = nil;
		NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
		[coordinator coordinateReadingItemAtURL:url options:NSFileCoordinatorReadingWithoutChanges error:&coordinateError byAccessor:^(NSURL *readURL) {
			NSError *copyError = nil;
			if (![fm copyItemAtPath:readURL.path toPath:[dataDir stringByAppendingPathComponent:dest] error:&copyError]) {
				error = copyError;
			}
		}];
		if (scoped) {
			[url stopAccessingSecurityScopedResource];
		}
		error = error ?: coordinateError;

		dispatch_async(dispatch_get_main_queue(), ^{
			[progress dismissViewControllerAnimated:YES completion:^{
				if (error) {
					NSLog(@"keybar: copy failed: %@", error);
					[weakSelf showError:error.localizedDescription];
				}
				else {
					handler(dest);
				}
			}];
		});
	});
}

// ---- show / hide

- (void)hideBar
{
	_hidden = YES;
	[[NSUserDefaults standardUserDefaults] setBool:YES forKey:kHiddenKey];
	[self applyHidden];
}

- (void)showBar
{
	_hidden = NO;
	[[NSUserDefaults standardUserDefaults] setBool:NO forKey:kHiddenKey];
	[self applyHidden];
}

- (void)applyHidden
{
	if (_hidden) {
		[self hideKeyboards];
	}
	_bar.hidden = _hidden;
	_showButton.hidden = !_hidden;
	[self setNeedsLayout];
}

- (void)keyboardWillChange:(NSNotification *)note
{
	_keyboardFrame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
	_softKeyboardShown = CGRectGetMinY(_keyboardFrame) < CGRectGetMaxY(UIScreen.mainScreen.bounds);
	if (_softKeyboardShown && CGRectGetHeight(_keyboardFrame) > 150) {
		[self setScreenKeyboardShown:NO];	/* one keyboard at a time */
	}
	/* With a hardware keyboard iOS shows only a thin shortcut bar; keys
	 * typed on a full software keyboard arrive as US positions. */
	keyinput_setsoftkeyboard(_softKeyboardShown && CGRectGetHeight(_keyboardFrame) > 150);
	[self setNeedsLayout];
}

- (void)keyboardWillHide:(NSNotification *)note
{
	(void)note;
	_keyboardFrame = CGRectNull;
	_softKeyboardShown = NO;
	keyinput_setsoftkeyboard(NO);
	[self setNeedsLayout];
}

// ---- layout

- (void)layoutSubviews
{
	[super layoutSubviews];
	CGRect bounds = self.bounds;
	UIEdgeInsets safe = self.safeAreaInsets;
	CGFloat viewW = bounds.size.width;
	CGFloat viewH = bounds.size.height;

	/* SDL draws the PC-98 screen (sw x sh, plus `pad` empty lines below it)
	 * aspect fit and centered */
	int sw = SCREEN_WIDTH, sh = SCREEN_HEIGHT;
	scrnmng_getsize(&sw, &sh);
	if (sw <= 0 || sh <= 0) {
		sw = SCREEN_WIDTH;
		sh = SCREEN_HEIGHT;
	}
	if ((sw != (int)_screenSize.width || sh != (int)_screenSize.height) && _zoom > 1) {
		_screenSize = CGSizeMake(sw, sh);
		[self setZoom:1 center:CGPointZero];		/* another screen mode */
	}
	_screenSize = CGSizeMake(sw, sh);
	[self updateFold];
	if (_screenKeyboardShown && (_fold == NP2FoldScreenLeft || _fold == NP2FoldScreenRight)) {
		[self layoutSideBySide:CGSizeMake(sw, sh)];
		return;
	}
	CGFloat sideGap = (viewW - sw * MIN(viewW / sw, viewH / sh)) / 2 - MAX(safe.left, safe.right);

	/* the app's own keyboard: at the bottom, at most about half the height.
	 * Folded, the lower half below the hinge (in the middle) is for input:
	 * the bar at the top of it, the keyboard filling the rest. */
	CGFloat keyboardHeight = 0;
	CGFloat hinge = round(viewH / 2);
	BOOL folded = _screenKeyboardShown && (_fold == NP2FoldLaptop);
	if (folded) {
		keyboardHeight = viewH - hinge - kOverlayBarHeight;
	}
	else if (_screenKeyboardShown) {
		CGFloat maxHeight = viewH * ((viewH > viewW) ? 0.45 : 0.5) - safe.bottom;
		keyboardHeight = [_screenKeyboard heightForWidth:viewW - safe.left - safe.right maxHeight:maxHeight] + safe.bottom;
	}
	if (_screenKeyboardShown) {
		_screenKeyboard.fillsHeight = folded;
		_screenKeyboard.frame = CGRectMake(0, viewH - keyboardHeight, viewW, keyboardHeight);
	}

	/* Wide screens (iPad) leave little room below; make SDL leave a band
	 * for the bar, shrinking the screen a little. */
	int pad = 0;
	int toppad = 0;
	if (folded) {
		/* The upper half is the screen's alone: as large as fits below the
		 * status bar, in the middle of what is left. SDL fits the screen
		 * with both bands to the height, so their sum sets the scale, and
		 * the band above, where the screen starts. */
		CGFloat available = hinge - safe.top;
		BOOL fullWidth = (viewW / sw <= available / sh);
		CGFloat s = fullWidth ? viewW / sw : available / sh;
		CGFloat screenTop = safe.top + (available - sh * s) / 2;
		/* rounded so that the scale is not larger than s */
		int total = fullWidth ? (int)floor(viewH / s) : (int)ceil(viewH / s);
		toppad = (int)floor(screenTop / s);
		pad = MAX(0, total - sh - toppad);
	}
	else if (_screenKeyboardShown) {
		/* the screen above the bar and the keyboard: shrink it to fit */
		CGFloat available = viewH - keyboardHeight - kOverlayBarHeight;
		if (viewW / sw <= available / sh) {
			pad = MAX(0, (int)((viewH - 2 * safe.top) / (viewW / sw)) - sh);	/* at the top, full width */
		}
		else {
			pad = MAX(0, (int)ceil(viewH / (available / sh)) - sh);			/* at the top, centered */
		}
	}
	else if (!_hidden && viewH > viewW) {
		/* portrait (iPad): screen at the top, the bar and the software
		 * keyboard below it */
		pad = MAX(0, (int)((viewH - 2 * safe.top) / (viewW / sw)) - sh);
	}
	else if (!_hidden && sideGap < kMinSideWidth) {
		int maxpad = sh / 8;
		for (pad = 0; pad < maxpad; pad++) {
			CGFloat s = MIN(viewW / sw, viewH / (sh + pad));
			CGFloat top = (viewH - (sh + pad) * s) / 2;
			if (viewH - top - sh * s >= kMaxBarHeight) {
				break;
			}
		}
	}
	scrnmng_setsidepads(0, 0);
	scrnmng_settoppad(toppad);
	scrnmng_setbottompad(pad);
	CGFloat scale = MIN(viewW / sw, viewH / (sh + toppad + pad));
	_trackpad.frame = bounds;
	[self setScreenRect:CGRectMake((viewW - sw * scale) / 2, (viewH - (sh + toppad + pad) * scale) / 2 + toppad * scale,
		sw * scale, sh * scale) scale:scale];
	CGFloat screenBottom = (viewH - (sh + toppad + pad) * scale) / 2 + (toppad + sh) * scale;
	CGFloat bottomGap = viewH - screenBottom;

	CGFloat bottom = bounds.size.height - keyboardHeight;
	if (!CGRectIsNull(_keyboardFrame) && self.window && !_screenKeyboardShown) {
		CGRect kb = [self convertRect:_keyboardFrame fromView:nil];
		if (CGRectGetMinY(kb) < bottom && CGRectGetHeight(kb) > 0) {
			bottom = CGRectGetMinY(kb);
		}
	}

	CGRect frame;
	BOOL vertical = NO;
	if (bottom < bounds.size.height) {
		/* above the software keyboard */
		frame = CGRectMake(0, bottom - kOverlayBarHeight, bounds.size.width, kOverlayBarHeight);
	}
	else if (bottomGap >= kMinBarHeight) {
		/* right below the screen */
		CGFloat height = MIN(bottomGap, kMaxBarHeight);
		frame = CGRectMake(safe.left, screenBottom, bounds.size.width - safe.left - safe.right, height);
	}
	else if (sideGap >= kMinSideWidth) {
		CGFloat width = MIN(sideGap, kMaxSideWidth);
		frame = CGRectMake(bounds.size.width - safe.right - width, safe.top, width,
			bounds.size.height - safe.top - safe.bottom);
		vertical = YES;
	}
	else {
		frame = CGRectMake(safe.left, bounds.size.height - safe.bottom - kOverlayBarHeight,
			bounds.size.width - safe.left - safe.right, kOverlayBarHeight);
	}
	_bar.frame = frame;
	if (vertical) {
		[self layoutVertical:frame.size];
	}
	else {
		[self layoutHorizontal:frame.size];
	}

	[self layoutDPadBelow:frame vertical:vertical keyboardTop:bottom];

	/* top right, left of the bar when that is a column there */
	CGSize speed = CGSizeMake(84, 22);
	CGFloat right = (vertical && !_hidden) ? CGRectGetMinX(frame) : bounds.size.width - safe.right;
	_speedLabel.frame = CGRectMake(right - speed.width - kGap, MAX(safe.top, kGap), speed.width, speed.height);
	[self layoutRecordButtonAt:CGPointMake(MAX(safe.left, kGap), MAX(safe.top, kGap))];

	CGSize show = CGSizeMake(44, 30);
	_showButton.frame = CGRectMake(bounds.size.width - safe.right - show.width - kGap,
		bounds.size.height - MAX(safe.bottom, kGap) - show.height, show.width, show.height);
}

/* Held like a book: the screen in one half, as large as fits and in the
 * middle of it; the bar at the top of the other half and the keyboard
 * filling the rest. SDL fits the screen with its bands to the view, so the
 * bands are what the view is in screen pixels, around where the screen goes. */
- (void)layoutSideBySide:(CGSize)screen
{
	CGRect bounds = self.bounds;
	UIEdgeInsets safe = self.safeAreaInsets;
	CGFloat viewW = bounds.size.width;
	CGFloat viewH = bounds.size.height;
	CGFloat hinge = round(viewW / 2);
	BOOL screenLeft = (_fold == NP2FoldScreenLeft);
	CGRect screenHalf = screenLeft
		? CGRectMake(safe.left, safe.top, hinge - safe.left, viewH - safe.top - safe.bottom)
		: CGRectMake(hinge, safe.top, viewW - safe.right - hinge, viewH - safe.top - safe.bottom);
	CGRect inputHalf = screenLeft
		? CGRectMake(hinge, 0, viewW - hinge, viewH)
		: CGRectMake(0, 0, hinge, viewH);

	CGFloat s = MIN(screenHalf.size.width / screen.width, screenHalf.size.height / screen.height);
	int totalW = (int)ceil(viewW / s);
	int totalH = (int)ceil(viewH / s);
	CGFloat scale = MIN(viewW / totalW, viewH / totalH);		/* what SDL uses, not above s */
	CGFloat originX = (viewW - totalW * scale) / 2;
	CGFloat originY = (viewH - totalH * scale) / 2;
	CGFloat screenX = CGRectGetMidX(screenHalf) - screen.width * scale / 2;
	CGFloat screenY = CGRectGetMidY(screenHalf) - screen.height * scale / 2;
	int left = MAX(0, (int)lround((screenX - originX) / scale));
	int top = MAX(0, (int)lround((screenY - originY) / scale));
	scrnmng_setsidepads(left, MAX(0, totalW - (int)screen.width - left));
	scrnmng_settoppad(top);
	scrnmng_setbottompad(MAX(0, totalH - (int)screen.height - top));
	_trackpad.frame = bounds;
	[self setScreenRect:CGRectMake(originX + left * scale, originY + top * scale, screen.width * scale, screen.height * scale)
	              scale:scale];

	CGFloat barTop = MAX(safe.top, kGap);
	CGFloat barHeight = _hidden ? 0 : kOverlayBarHeight;
	CGRect bar = CGRectMake(inputHalf.origin.x + (screenLeft ? 0 : safe.left), barTop,
		inputHalf.size.width - (screenLeft ? safe.right : safe.left), kOverlayBarHeight);
	_bar.frame = bar;
	[self layoutHorizontal:bar.size];
	_screenKeyboard.fillsHeight = YES;
	_screenKeyboard.frame = CGRectMake(bar.origin.x, barTop + barHeight, bar.size.width, viewH - barTop - barHeight);
	[self layoutDPadBelow:bar vertical:NO keyboardTop:0];

	CGSize speed = CGSizeMake(84, 22);
	_speedLabel.frame = CGRectMake(CGRectGetMaxX(screenHalf) - speed.width - kGap, MAX(safe.top, kGap), speed.width, speed.height);
	[self layoutRecordButtonAt:CGPointMake(screenHalf.origin.x + kGap, MAX(safe.top, kGap))];
	CGSize show = CGSizeMake(44, 30);
	_showButton.frame = CGRectMake(CGRectGetMaxX(inputHalf) - safe.right - show.width - kGap,
		MAX(safe.top, kGap), show.width, show.height);
}

/* Portrait: in the space below the bar, at the bottom right (thumb).
 * Landscape: over the bottom left of the screen when turned on. */
- (void)layoutDPadBelow:(CGRect)barFrame vertical:(BOOL)vertical keyboardTop:(CGFloat)keyboardTop
{
	CGRect bounds = self.bounds;
	UIEdgeInsets safe = self.safeAreaInsets;
	BOOL keyboard = keyboardTop < bounds.size.height;
	BOOL wanted = [[NSUserDefaults standardUserDefaults] boolForKey:[self dpadKey]];
	BOOL phone = (self.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPhone);
	CGRect frame = CGRectZero;

	if (_hidden || keyboard || !wanted) {
		/* nothing */
	}
	else if ([self isPortrait]) {
		CGFloat top = CGRectGetMaxY(barFrame) + 12;
		CGFloat bottom = bounds.size.height - MAX(safe.bottom, 12) - 12;
		CGFloat size = MIN(MIN(bottom - top, bounds.size.width * 0.55), 240);
		if (size >= 110) {
			frame = CGRectMake(bounds.size.width - safe.right - 24 - size, bottom - size, size, size);
		}
	}
	else {
		CGFloat size = phone ? 130 : 170;
		CGFloat bottom = vertical ? bounds.size.height - MAX(safe.bottom, 12) - 8 : CGRectGetMinY(barFrame) - 12;
		frame = CGRectMake(safe.left + 16, bottom - size, size, size);
	}
	_dpad.hidden = CGRectIsEmpty(frame);
	_dpad.frame = frame;
	_dpad.overlay = ![self isPortrait];
	_dpadButton.tintColor = wanted ? UIColor.systemOrangeColor : UIColor.whiteColor;
	_softkbdButton.tintColor = (_screenKeyboardShown || keyboard) ? UIColor.systemOrangeColor : UIColor.whiteColor;
}

- (void)layoutHorizontal:(CGSize)size
{
	CGFloat h = size.height - kGap * 2;
	CGFloat icon = MAX(h, 36);
	_menuButton.frame = CGRectMake(kGap, kGap, icon, h);
	_softkbdButton.frame = CGRectMake(kGap + icon, kGap, icon, h);
	_dpadButton.frame = CGRectMake(kGap + icon * 2, kGap, icon, h);
	_hideButton.frame = CGRectMake(size.width - kGap - icon, kGap, icon, h);
	CGFloat left = CGRectGetMaxX(_dpadButton.frame) + kGap;
	_scroll.frame = CGRectMake(left, 0, CGRectGetMinX(_hideButton.frame) - kGap - left, size.height);

	CGFloat x = 0;
	for (NSUInteger i = 0; i < _keys.count; i++) {
		NP2KeyButton *button = _keys[i];
		if (_separatorBefore[i].boolValue && i > 0) {
			x += kGroupGap - kGap;
		}
		CGFloat w = MAX(44, ceil([button.titleLabel sizeThatFits:CGSizeMake(200, h)].width) + 12);
		button.frame = CGRectMake(x, kGap, w, h);
		x += w + kGap;
	}
	_scroll.contentSize = CGSizeMake(x - kGap, size.height);
}

- (void)layoutVertical:(CGSize)size
{
	CGFloat w = size.width - kGap * 2;
	CGFloat h = 34;
	_menuButton.frame = CGRectMake(kGap, kGap, w, h);
	_softkbdButton.frame = CGRectMake(kGap, kGap + h, w, h);
	_dpadButton.frame = CGRectMake(kGap, kGap + h * 2, w, h);
	_hideButton.frame = CGRectMake(kGap, size.height - kGap - h, w, h);
	CGFloat top = CGRectGetMaxY(_dpadButton.frame) + kGap;
	_scroll.frame = CGRectMake(0, top, size.width, CGRectGetMinY(_hideButton.frame) - kGap - top);

	CGFloat y = 0;
	for (NSUInteger i = 0; i < _keys.count; i++) {
		if (_separatorBefore[i].boolValue && i > 0) {
			y += kGroupGap - kGap;
		}
		_keys[i].frame = CGRectMake(kGap, y, w, h);
		y += h + kGap;
	}
	_scroll.contentSize = CGSizeMake(size.width, y - kGap);
}

// ---- testing

- (void)debugCommand:(NSString *)command
{
	if (diskedit_debugcommand(command) || gamepad_debugcommand(command)) {
		return;
	}
	if ([command isEqualToString:@"!midiports"]) {
		midiport_debugdump();
	}
	else if ([command isEqualToString:@"!copyscreen"]) {
		clipboard_copyscreen();
	}
	else if ([command isEqualToString:@"!paste"]) {
		/* puts debugpaste.txt (data directory) on the clipboard and types it without asking */
		NSString *text = [NSString stringWithContentsOfFile:@"debugpaste.txt" encoding:NSUTF8StringEncoding error:nil];
		[UIPasteboard generalPasteboard].string = text ?: @"";
		NSLog(@"keybar: paste, %lu left out", (unsigned long)clipboard_type([UIPasteboard generalPasteboard].string ?: @""));
	}
	else if ([command isEqualToString:@"!pbdump"]) {
		/* the clipboard's text -> pasteboard.txt */
		[[UIPasteboard generalPasteboard].string ?: @"" writeToFile:@"pasteboard.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
	}
	else if ([command hasPrefix:@"!insert"] && command.length > 9) {
		insert_fdd((REG8)([command characterAtIndex:7] - '1'), [command substringFromIndex:9]);
	}
	else if ([command isEqualToString:@"!eject1"] || [command isEqualToString:@"!eject2"]) {
		diskdrv_setfdd((REG8)([command characterAtIndex:6] - '1'), NULL, 0);
	}
	else if ([command hasPrefix:@"!importhdd"] && command.length > 13) {
		/* "!importhdd20:<absolute path>": as if picked outside the data directory */
		REG8 drv = (REG8)strtol([command substringWithRange:NSMakeRange(10, 2)].UTF8String, NULL, 16);
		__weak NP2KeyBar *weakSelf = self;
		[self importURL:[NSURL fileURLWithPath:[command substringFromIndex:13]] into:kHddDir handler:^(NSString *path) {
			[weakSelf setHdd:drv path:path];
		}];
	}
	else if ([command hasPrefix:@"!hdd"] && command.length >= 6) {
		/* "!hdd20:<path>" sets SCSI #0, "!hdd20" removes it */
		REG8 drv = (REG8)strtol([command substringWithRange:NSMakeRange(4, 2)].UTF8String, NULL, 16);
		NSString *path = (command.length > 7) ? [command substringFromIndex:7] : nil;
		set_hdd(drv, path);
	}
	else if ([command isEqualToString:@"!dumphddmenu"]) {
		UIMenu *menu = [self hddMenu];
		NSLog(@"keybar: menu %@ (%@)", menu.title, menu.subtitle);
		for (UIMenuElement *slot in menu.children) {
			NSMutableArray *titles = [NSMutableArray array];
			for (UIMenuElement *item in ((UIMenu *)slot).children) {
				[titles addObject:item.title];
			}
			NSLog(@"keybar:   %@ = %@ [%@]", slot.title, slot.subtitle, [titles componentsJoinedByString:@", "]);
		}
	}
	else if ([command isEqualToString:@"!settings"]) {
		settingsview_present([self hostController]);
	}
	else if ([command hasPrefix:@"!style:"]) {
		[[NSUserDefaults standardUserDefaults] setInteger:[command substringFromIndex:7].integerValue forKey:kSettingScreenStyle];
	}
	else if ([command isEqualToString:@"!help"]) {
		settingsview_presenthelp([self hostController]);
	}
	else if ([command isEqualToString:@"!profiles"]) {
		settingsview_presentprofiles([self hostController]);
	}
	else if ([command hasPrefix:@"!newdisk:"]) {
		/* "!newdisk:<index>:<MB>" */
		NSArray<NSString *> *args = [[command substringFromIndex:9] componentsSeparatedByString:@":"];
		settingsview_debugnewdisk(args[0].intValue, (unsigned int)args.lastObject.intValue);
	}
	else if ([command hasPrefix:@"!orient:"]) {
		/* "!orient:portrait" / "!orient:landscape" */
		if (@available(iOS 16.0, *)) {
			BOOL portrait = [command hasSuffix:@"portrait"];
			UIWindowSceneGeometryPreferencesIOS *prefs = [[UIWindowSceneGeometryPreferencesIOS alloc]
				initWithInterfaceOrientations:portrait ? UIInterfaceOrientationMaskPortrait : UIInterfaceOrientationMaskLandscapeRight];
			[self.window.windowScene requestGeometryUpdateWithPreferences:prefs errorHandler:^(NSError *error) {
				NSLog(@"keybar: orientation request failed: %@", error);
			}];
		}
	}
	else if ([command hasPrefix:@"!dpad:"]) {
		/* "!dpad:up" etc. presses an arrow; "!dpad:toggle" is the bar button */
		NSString *arg = [command substringFromIndex:6];
		if ([arg isEqualToString:@"toggle"]) {
			[self toggleDPad];
		}
		else {
			[_dpad tapDirection:arg];
		}
	}
	else if ([command isEqualToString:@"!showmenu"]) {
		if (@available(iOS 17.4, *)) {
			[_menuButton performPrimaryAction];
		}
	}
	else if ([command hasPrefix:@"!tap:"]) {
		settingsview_debugtap([command substringFromIndex:5].UTF8String);
	}
	else if ([command isEqualToString:@"!guide"]) {
		settingsview_presentguide([self hostController]);
	}
	else if ([command isEqualToString:@"!dismiss"]) {
		[[self hostController] dismissViewControllerAnimated:NO completion:nil];
	}
	else if ([command isEqualToString:@"!reset"]) {
		reset_machine();
	}
	else if ([command isEqualToString:@"!np2menu"]) {
		sysmenu_menuopen(0, 0, 0);
	}
	else if ([command isEqualToString:@"!hide"]) {
		[self hideBar];
	}
	else if ([command isEqualToString:@"!show"]) {
		[self showBar];
	}
	else if ([command hasPrefix:@"!kbdkind:"]) {
		/* "!kbdkind:pc98" / "!kbdkind:system": as chosen in the button's menu */
		[self chooseKeyboard:[command substringFromIndex:9]];
	}
	else if ([command hasPrefix:@"!kbdtap:"]) {
		/* "!kbdtap:<key id>" taps a key on the app's keyboard */
		NSString *identifier = [command substringFromIndex:8];
		if (![_screenKeyboard tapKey:identifier]) {
			NSLog(@"keybar: no key %@", identifier);
		}
	}
	else if ([command hasPrefix:@"!kbdhold:"]) {
		/* "!kbdhold:<key id>/<seconds>" */
		NSArray<NSString *> *args = [[command substringFromIndex:9] componentsSeparatedByString:@"/"];
		if (![_screenKeyboard holdKey:args[0] seconds:(args.count > 1) ? args[1].doubleValue : 1]) {
			NSLog(@"keybar: no key %@", args[0]);
		}
	}
	else if ([command hasPrefix:@"!kbdblock:"]) {
		[_screenKeyboard showBlock:[command substringFromIndex:10].integerValue];
	}
	else if ([command hasPrefix:@"!click:"]) {
		/* "!click:<x>/<y>": a touch at (x, y) points on the SDL view, for
		 * the NP2 menu; also shows where it was */
		NSArray<NSString *> *xy = [[command substringFromIndex:7] componentsSeparatedByString:@"/"];
		float x = xy[0].floatValue, y = (xy.count > 1) ? xy[1].floatValue : 0;
		np21_pushmouse(0, x, y);
		np21_pushmouse(1, x, y);
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			np21_pushmouse(2, x, y);
		});
		UIView *mark = [[UIView alloc] initWithFrame:CGRectMake(x - 3, y - 3, 6, 6)];
		mark.backgroundColor = UIColor.systemRedColor;
		mark.userInteractionEnabled = NO;
		[self addSubview:mark];
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			[mark removeFromSuperview];
		});
	}
	else if ([command hasPrefix:@"!pad"]) {
		if (![_trackpad debugCommand:command]) {
			NSLog(@"keybar: unknown command %@", command);
		}
	}
	else if ([command hasPrefix:@"!midiclock:"]) {
		[[NSUserDefaults standardUserDefaults] setBool:[command hasSuffix:@"on"] forKey:kSettingMidiClockOut];
	}
	else if ([command isEqualToString:@"!shot"]) {
		capture_screenshot([self hostController]);
	}
	else if ([command hasPrefix:@"!rec:"]) {
		/* "!rec:start" / "!rec:stop" (video) */
		if ([command hasSuffix:@"start"]) {
			capture_startrecording();
		}
		else {
			capture_stoprecording(nil);
		}
		[self refreshRecording];
	}
	else if ([command hasPrefix:@"!midirec:"]) {
		if ([command hasSuffix:@"start"]) {
			midirec_start();
		}
		else {
			midirec_stop(nil);
		}
		[self refreshRecording];
	}
	else if ([command hasPrefix:@"!slot:"]) {
		/* "!slot:save:<n>" / "!slot:load:<n>" (1-based, no questions) */
		NSArray<NSString *> *args = [[command substringFromIndex:6] componentsSeparatedByString:@":"];
		NSInteger slot = (args.count > 1) ? args[1].integerValue - 1 : 0;
		if ([args[0] isEqualToString:@"save"]) {
			profile_saveslot(slot);
		}
		else {
			NSLog(@"keybar: slot %ld check %d", (long)slot + 1, profile_checkslot(slot));
			profile_loadslot(slot);
		}
	}
	else if ([command hasPrefix:@"!zoom:"]) {
		/* "!zoom:<zoom>/<x>/<y>" (x, y in PC-98 pixels) */
		NSArray<NSString *> *args = [[command substringFromIndex:6] componentsSeparatedByString:@"/"];
		[self setZoom:args[0].doubleValue center:CGPointMake((args.count > 1) ? args[1].doubleValue : 0, (args.count > 2) ? args[2].doubleValue : 0)];
	}
	else if ([command hasPrefix:@"!profile:"]) {
		/* "!profile:new:<name>:<copy|share|none>", "!profile:switch:<name>",
		 * "!profile:delete:<name>", "!profile:export:<name>" (to exports/),
		 * "!profile:import:<folder in the data directory>", "!profile:list" */
		NSArray<NSString *> *args = [[command substringFromIndex:9] componentsSeparatedByString:@":"];
		if ([args[0] isEqualToString:@"new"] && args.count > 2) {
			NSArray<NSString *> *kinds = @[ @"copy", @"share", @"none" ];
			NSError *error = nil;
			NSString *identifier = profile_create(args[1], (NP2ProfileDisks)[kinds indexOfObject:args[2]], &error);
			NSLog(@"keybar: profile %@ %@", identifier, error.localizedDescription ?: @"");
		}
		else if ([args[0] isEqualToString:@"export"] && args.count > 1) {
			/* into exports/ in the data directory */
			for (NSString *identifier in profile_ids()) {
				if ([profile_name(identifier) isEqualToString:args[1]]) {
					NSError *error = nil;
					NSURL *package = profile_export(identifier, &error);
					[[NSFileManager defaultManager] createDirectoryAtPath:@"exports" withIntermediateDirectories:YES attributes:nil error:nil];
					NSString *to = [@"exports" stringByAppendingPathComponent:package.lastPathComponent];
					[[NSFileManager defaultManager] removeItemAtPath:to error:nil];
					[[NSFileManager defaultManager] moveItemAtPath:package.path toPath:to error:&error];
					NSLog(@"keybar: exported to %@ %@", to, error.localizedDescription ?: @"");
				}
			}
		}
		else if ([args[0] isEqualToString:@"import"] && args.count > 1) {
			NSError *error = nil;
			NSString *path = [[NSFileManager defaultManager].currentDirectoryPath stringByAppendingPathComponent:args[1]];
			NSString *identifier = profile_import([NSURL fileURLWithPath:path], &error);
			NSLog(@"keybar: imported %@ %@", identifier, error.localizedDescription ?: @"");
		}
		else if (([args[0] isEqualToString:@"switch"] || [args[0] isEqualToString:@"delete"]) && args.count > 1) {
			for (NSString *identifier in profile_ids()) {
				if ([profile_name(identifier) isEqualToString:args[1]]) {
					if ([args[0] isEqualToString:@"switch"]) {
						profile_switch(identifier);
					}
					else {
						profile_delete(identifier);
					}
				}
			}
		}
		for (NSString *identifier in profile_ids()) {
			NSLog(@"keybar: profile %@%@ %@", [identifier isEqualToString:profile_active()] ? @"*" : @"",
				profile_name(identifier), [profile_disks(identifier) componentsJoinedByString:@", "]);
		}
	}
	else if ([command hasPrefix:@"!foldland:"]) {
		/* "!foldland:0|1|2": the layout held like a book (settings) */
		[[NSUserDefaults standardUserDefaults] setInteger:[command substringFromIndex:10].integerValue forKey:kSettingLandscapeFold];
	}
	else if ([command hasPrefix:@"!trackpad:"]) {
		[[NSUserDefaults standardUserDefaults] setBool:[[command substringFromIndex:10] isEqualToString:@"on"] forKey:kSettingTrackpad];
	}
	else if ([command hasPrefix:@"!hinge:"]) {
		/* "!hinge:partial" / "open" / "closed" / "none": as if the hinge moved
		 * (the Simulator's hinge is only in DeviceHub's window) */
		NSDictionary<NSString *, NSNumber *> *postures = @{
			@"none": @(NP2HingePostureUnavailable), @"closed": @(NP2HingePostureClosed),
			@"partial": @(NP2HingePosturePartiallyOpen), @"open": @(NP2HingePostureFullyOpen),
		};
		NSNumber *posture = postures[[command substringFromIndex:7]];
		if (posture) {
			[self hingeChanged:posture.integerValue];
		}
	}
	else if ([command isEqualToString:@"!softkbd"]) {
		[self toggleSoftKeyboard];
	}
	else if ([command hasPrefix:@"!softtype:"]) {
		/* as if typed on the software keyboard */
		[s_textfield insertText:[command substringFromIndex:10]];
	}
	else {
		for (NP2KeyButton *button in _keys) {
			if ([button.accessibilityIdentifier isEqualToString:command]) {
				[button sendActionsForControlEvents:UIControlEventTouchDown];
				[button sendActionsForControlEvents:UIControlEventTouchUpInside];
				return;
			}
		}
		NSLog(@"keybar: unknown command %@", command);
	}
}

@end

// ---- installation

static NP2KeyBar *s_keybar;

/* Command + C copies the text screen, Command + V types the clipboard. */
static void command_key(char letter)
{
	if (letter == 'c') {
		clipboard_copyscreen();
	}
	else if (letter == 'v' && !clipboard_istyping()) {
		clipboard_paste([s_keybar hostController]);
	}
}

static void refresh_modifiers(void)
{
	[s_keybar refreshModifiers];
}

/* SDL's hidden text field behind the software keyboard. The default
 * keyboard follows the system language (kana on Japanese systems), and smart
 * punctuation would turn ' and - into other characters. */
static void setup_text_field(UIViewController *controller)
{
	@try {
		id field = [controller valueForKey:@"textField"];
		if ([field isKindOfClass:[UITextField class]]) {
			UITextField *textField = field;
			s_textfield = textField;
			textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
			textField.autocorrectionType = UITextAutocorrectionTypeNo;
			textField.keyboardType = UIKeyboardTypeASCIICapable;
			textField.smartQuotesType = UITextSmartQuotesTypeNo;
			textField.smartDashesType = UITextSmartDashesTypeNo;
			textField.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
			textField.spellCheckingType = UITextSpellCheckingTypeNo;
		}
	}
	@catch (NSException *e) {
		NSLog(@"keybar: no SDL text field (%@)", e.reason);
	}
}

static UIViewController *sdl_controller(void)
{
	return np21_sdl_uiwindow().rootViewController;
}

void keybar_initialize(void)
{
	/* np2_main() creates the SDL window later; the timer fires while SDL
	 * pumps the run loop. */
	[NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *timer) {
		UIViewController *controller = sdl_controller();
		UIView *view = controller.view;
		if (view == nil) {
			return;
		}
		[timer invalidate];
		setup_text_field(controller);
		/* SDL clears the event filter until its event loop has started */
		keyinput_initialize();
		s_keybar = [[NP2KeyBar alloc] initWithFrame:view.bounds];
		[view addSubview:s_keybar];
		keyinput_onchange = refresh_modifiers;
		keyinput_oncommand = command_key;
		lifecycle_start();
		dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
			settingsview_presentguideifneeded([s_keybar hostController]);
		});
	}];
}

void keybar_pickhdd(unsigned char drv)
{
	[s_keybar pickFileInto:kHddDir handler:^(NSString *path) {
		REG8 slot = drv;
		if (slot == KEYBAR_HDD_AUTO) {
			/* Virtual98 (.hdd) images are SCSI disks; the others (.hdi, .nhd,
			 * .thd, ...) are SASI/IDE disks */
			slot = [path.pathExtension.lowercaseString isEqualToString:@"hdd"] ? 0x20 : 0x00;
		}
		[s_keybar setHdd:slot path:path];
	}];
}

void keybar_sethdd(unsigned char drv, const char *path)
{
	[s_keybar setHdd:drv path:path ? [NSString stringWithUTF8String:path] : nil];
}

void keybar_resetmachine(void)
{
	reset_machine();
}

void keybar_debugcommand(const char *command)
{
	NSString *str = [NSString stringWithUTF8String:command];
	dispatch_async(dispatch_get_main_queue(), ^{
		[s_keybar debugCommand:str];
	});
}
