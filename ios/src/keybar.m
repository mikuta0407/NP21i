/**
 * @file	keybar.m
 * @brief	On-screen bar with PC-98 keys and the app menu
 *
 * The PC-98 keys that iPad / iPhone keyboards lack (STOP, COPY, f.1-f.10,
 * vf.1-vf.5, HOME/CLR, HELP, ROLL UP/DOWN, GRPH, KANA, XFER, NFER, ...),
 * plus a menu for floppy images, reset and the NP2 menu.
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

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <SDL2/SDL.h>
#include <SDL2/SDL_syswm.h>
#include <pccore.h>
#include <nevent.h>
#include <fdd/diskdrv.h>
#include <diskimage/fddfile.h>
#include <kbtrans.h>
#include <sysmenu.h>

enum {
	SCREEN_WIDTH	= 640,
	SCREEN_HEIGHT	= 400
};

static const CGFloat kMinBarHeight = 30;
static const CGFloat kMaxBarHeight = 44;
static const CGFloat kOverlayBarHeight = 40;
static const CGFloat kMinSideWidth = 44;
static const CGFloat kMaxSideWidth = 76;
static const CGFloat kGap = 4;
static const CGFloat kGroupGap = 12;

static NSString *const kHiddenKey = @"keybar_hidden";
static NSString *const kFddDir = @"fdd";

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

// ---- views

static __weak UITextField *s_textfield;	/* SDL's, behind the software keyboard */

@interface NP2KeyButton : UIButton
@property (nonatomic) UINT8 code;
@property (nonatomic) KeyKind kind;
@end

@implementation NP2KeyButton
@end

@interface NP2KeyBar : UIView <UIDocumentPickerDelegate>
- (void)refreshModifiers;
@end

@implementation NP2KeyBar {
	UIView *_bar;
	UIScrollView *_scroll;
	UIButton *_menuButton;
	UIButton *_softkbdButton;
	UIButton *_hideButton;
	UIButton *_showButton;
	NSMutableArray<NP2KeyButton *> *_keys;
	NSMutableArray<NSNumber *> *_separatorBefore;	/* per key */
	CGRect _keyboardFrame;							/* software keyboard, in window coordinates */
	BOOL _softKeyboardShown;
	REG8 _pickingDrive;
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

- (void)toggleSoftKeyboard
{
	/* SDL enables text input from the start without showing the keyboard,
	 * so look at the keyboard itself. */
	if (_softKeyboardShown) {
		SDL_StopTextInput();
	}
	else {
		SDL_StartTextInput();
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
				[weakSelf pickDiskForDrive:drive];
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
	UIAction *reset = [UIAction actionWithTitle:@"リセット" image:[UIImage systemImageNamed:@"arrow.counterclockwise"]
	                                identifier:nil handler:^(UIAction *action) {
		(void)action;
		[weakSelf confirmReset];
	}];
	reset.attributes = UIMenuElementAttributesDestructive;
	UIAction *np2menu = [UIAction actionWithTitle:@"NP2 メニュー (F11)" image:[UIImage systemImageNamed:@"gearshape"]
	                                  identifier:nil handler:^(UIAction *action) {
		(void)action;
		sysmenu_menuopen(0, 0, 0);
	}];
	return [UIMenu menuWithChildren:@[
		[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[ fdd ]],
		[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[ np2menu, reset ]],
	]];
}

- (UIViewController *)hostController
{
	UIResponder *responder = self;
	while (responder && ![responder isKindOfClass:[UIViewController class]]) {
		responder = responder.nextResponder;
	}
	return (UIViewController *)responder;
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

- (void)pickDiskForDrive:(REG8)drive
{
	_pickingDrive = drive;
	UIDocumentPickerViewController *picker =
		[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeData ] asCopy:NO];
	picker.delegate = self;
	picker.directoryURL = [NSURL fileURLWithPath:[[NSFileManager defaultManager] currentDirectoryPath] isDirectory:YES];
	[[self hostController] presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
	(void)controller;
	NSURL *url = urls.firstObject;
	if (url == nil) {
		return;
	}
	NSString *path = [self localPathForPickedURL:url];
	if (path) {
		insert_fdd(_pickingDrive, path);
	}
}

/* Files inside the app's data directory are used in place; others (iCloud,
 * other apps) are copied into fdd/ so that they stay usable and writable.
 * Returns a path relative to the data directory (the current directory). */
- (NSString *)localPathForPickedURL:(NSURL *)url
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *dataDir = [fm.currentDirectoryPath stringByResolvingSymlinksInPath];
	NSString *picked = [url.path stringByResolvingSymlinksInPath];
	if ([picked hasPrefix:[dataDir stringByAppendingString:@"/"]]) {
		return [picked substringFromIndex:dataDir.length + 1];
	}

	BOOL scoped = [url startAccessingSecurityScopedResource];
	[fm createDirectoryAtPath:kFddDir withIntermediateDirectories:YES attributes:nil error:nil];
	NSString *dest = [kFddDir stringByAppendingPathComponent:url.lastPathComponent];
	NSError *error = nil;
	NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
	__block BOOL copied = NO;
	[coordinator coordinateReadingItemAtURL:url options:NSFileCoordinatorReadingWithoutChanges error:&error byAccessor:^(NSURL *readURL) {
		NSError *copyError = nil;
		[fm removeItemAtPath:dest error:nil];
		copied = [fm copyItemAtPath:readURL.path toPath:dest error:&copyError];
		if (!copied) {
			NSLog(@"keybar: copy failed: %@", copyError);
		}
	}];
	if (scoped) {
		[url stopAccessingSecurityScopedResource];
	}
	if (!copied) {
		NSString *message = error.localizedDescription ?: @"ファイルをコピーできませんでした。";
		UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"ディスクを読み込めません"
		                                                               message:message
		                                                        preferredStyle:UIAlertControllerStyleAlert];
		[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
		[[self hostController] presentViewController:alert animated:YES completion:nil];
		return nil;
	}
	return dest;
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
	keyinput_setsoftkeyboard(_softKeyboardShown);
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

	/* where SDL draws the screen: aspect fit, centered */
	CGFloat scale = MIN(bounds.size.width / SCREEN_WIDTH, bounds.size.height / SCREEN_HEIGHT);
	CGFloat screenW = SCREEN_WIDTH * scale;
	CGFloat screenH = SCREEN_HEIGHT * scale;
	CGFloat bottomGap = (bounds.size.height - screenH) / 2;
	CGFloat sideGap = (bounds.size.width - screenW) / 2 - MAX(safe.left, safe.right);

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
		CGFloat height = MIN(bottomGap, kMaxBarHeight);
		frame = CGRectMake(safe.left, bounds.size.height - height, bounds.size.width - safe.left - safe.right, height);
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
	for (Uint32 id = 1; id < 8; id++) {
		SDL_Window *window = SDL_GetWindowFromID(id);
		if (window == NULL) {
			continue;
		}
		SDL_SysWMinfo info;
		SDL_VERSION(&info.version);
		if (SDL_GetWindowWMInfo(window, &info) && info.subsystem == SDL_SYSWM_UIKIT) {
			return info.info.uikit.window.rootViewController;
		}
	}
	return nil;
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
	}];
}

void keybar_debugcommand(const char *command)
{
	NSString *str = [NSString stringWithUTF8String:command];
	dispatch_async(dispatch_get_main_queue(), ^{
		[s_keybar debugCommand:str];
	});
}
