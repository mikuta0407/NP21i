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
 * Runs on the main thread, which is also where the emulator runs (SDL pumps
 * the UIKit run loop from its event loop), so the core is called directly.
 */

#include "compiler.h"
#include "keybar.h"
#include "keyinput.h"
#include "lifecycle.h"
#include "settings.h"
#include "settingsview.h"

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "sdlcompat.h"
#include <pccore.h>
#include <nevent.h>
#include <fdd/diskdrv.h>
#include <fdd/sxsi.h>
#include <diskimage/fddfile.h>
#include <kbtrans.h>
#include <sysmenu.h>
#include <scrnmng.h>

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

@interface NP2KeyBar : UIView <UIDocumentPickerDelegate>
- (void)refreshModifiers;
- (UIViewController *)hostController;
- (void)pickFileInto:(NSString *)dir handler:(void (^)(NSString *path))handler;
- (void)setHdd:(REG8)drv path:(NSString *)path;
@end

@implementation NP2KeyBar {
	UIView *_bar;
	UIScrollView *_scroll;
	UIButton *_menuButton;
	UIButton *_softkbdButton;
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
	[_bar addSubview:_softkbdButton];

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

	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	[nc addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillChangeFrameNotification object:nil];
	[nc addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];

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
	}];
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

- (void)toggleSoftKeyboard
{
	/* SDL enables text input from the start without showing the keyboard,
	 * so look at the keyboard itself. */
	if (_softKeyboardShown) {
		np21_stoptextinput();
	}
	else {
		np21_starttextinput();
		/* SDL3 sets the text input traits again on every start */
		setup_text_field(sdl_controller());
		[s_textfield reloadInputViews];
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
	UIAction *settings = [UIAction actionWithTitle:@"設定…" image:[UIImage systemImageNamed:@"gearshape"]
	                                   identifier:nil handler:^(UIAction *action) {
		(void)action;
		settingsview_present([weakSelf hostController]);
	}];
	UIAction *np2menu = [UIAction actionWithTitle:@"NP2 メニュー (F11)" image:[UIImage systemImageNamed:@"slider.horizontal.3"]
	                                  identifier:nil handler:^(UIAction *action) {
		(void)action;
		sysmenu_menuopen(0, 0, 0);
	}];
	return [UIMenu menuWithChildren:@[
		[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[ fdd, hdd ]],
		[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[ settings, np2menu, reset ]],
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
	_bar.hidden = _hidden;
	_showButton.hidden = !_hidden;
	[self setNeedsLayout];
}

- (void)keyboardWillChange:(NSNotification *)note
{
	_keyboardFrame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
	_softKeyboardShown = CGRectGetMinY(_keyboardFrame) < CGRectGetMaxY(UIScreen.mainScreen.bounds);
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
	_screenSize = CGSizeMake(sw, sh);
	CGFloat sideGap = (viewW - sw * MIN(viewW / sw, viewH / sh)) / 2 - MAX(safe.left, safe.right);

	/* Wide screens (iPad) leave little room below; make SDL leave a band
	 * for the bar, shrinking the screen a little. */
	int pad = 0;
	if (!_hidden && viewH > viewW) {
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
	scrnmng_setbottompad(pad);
	CGFloat scale = MIN(viewW / sw, viewH / (sh + pad));
	CGFloat screenBottom = (viewH - (sh + pad) * scale) / 2 + sh * scale;
	CGFloat bottomGap = viewH - screenBottom;

	CGFloat bottom = bounds.size.height;
	if (!CGRectIsNull(_keyboardFrame) && self.window) {
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

	/* top right, left of the bar when that is a column there */
	CGSize speed = CGSizeMake(84, 22);
	CGFloat right = (vertical && !_hidden) ? CGRectGetMinX(frame) : bounds.size.width - safe.right;
	_speedLabel.frame = CGRectMake(right - speed.width - kGap, MAX(safe.top, kGap), speed.width, speed.height);

	CGSize show = CGSizeMake(44, 30);
	_showButton.frame = CGRectMake(bounds.size.width - safe.right - show.width - kGap,
		bounds.size.height - MAX(safe.bottom, kGap) - show.height, show.width, show.height);
}

- (void)layoutHorizontal:(CGSize)size
{
	CGFloat h = size.height - kGap * 2;
	CGFloat icon = MAX(h, 36);
	_menuButton.frame = CGRectMake(kGap, kGap, icon, h);
	_softkbdButton.frame = CGRectMake(kGap + icon, kGap, icon, h);
	_hideButton.frame = CGRectMake(size.width - kGap - icon, kGap, icon, h);
	CGFloat left = CGRectGetMaxX(_softkbdButton.frame) + kGap;
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
	_hideButton.frame = CGRectMake(kGap, size.height - kGap - h, w, h);
	CGFloat top = CGRectGetMaxY(_softkbdButton.frame) + kGap;
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
	if ([command hasPrefix:@"!insert"] && command.length > 9) {
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
	else if ([command hasPrefix:@"!newdisk:"]) {
		/* "!newdisk:<index>:<MB>" */
		NSArray<NSString *> *args = [[command substringFromIndex:9] componentsSeparatedByString:@":"];
		settingsview_debugnewdisk(args[0].intValue, (unsigned int)args.lastObject.intValue);
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

void keybar_debugcommand(const char *command)
{
	NSString *str = [NSString stringWithUTF8String:command];
	dispatch_async(dispatch_get_main_queue(), ^{
		[s_keybar debugCommand:str];
	});
}
