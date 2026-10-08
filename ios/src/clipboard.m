/**
 * @file	clipboard.m
 * @brief	Copying the PC-98 text screen, and typing text from the clipboard
 *
 * Pasting types: each character becomes the PC-98 key (and SHIFT / KANA)
 * that types it, pressed and released one step at a time with a timer, so
 * that the guest reads them as from the keyboard. The steps are slow enough
 * for the BIOS key buffer (16 keys) of a program that reads keys often.
 */

#include "compiler.h"
#include "clipboard.h"
#include "textscreen.h"
#include "keyinput.h"

#include <keystat.h>

enum {
	STEP_DOWN,
	STEP_UP,
	STEP_KANA		/* toggles the KANA lock */
};

enum {
	STEP_MS			= 25,		/* between steps (a key: down, then up) */
	ASK_LENGTH		= 2000		/* longer texts are confirmed first (about a minute and a half) */
};

typedef struct {
	UINT8	type;
	UINT8	code;
} TYPESTEP;

#define S	0x80		/* with SHIFT */
#define NONE	0xff

/* ASCII 0x20-0x7e -> PC-98 key (JIS-like layout, as kbdlayout.m draws it); letters unshifted */
static const UINT8 s_ascii[0x5f] = {
	0x34,		0x01 | S,	0x02 | S,	0x03 | S,	0x04 | S,	0x05 | S,	0x06 | S,	0x07 | S,	/*  !"#$%&' */
	0x08 | S,	0x09 | S,	0x27 | S,	0x26 | S,	0x30,		0x0b,		0x31,		0x32,		/* ()*+,-./ */
	0x0a,		0x01,		0x02,		0x03,		0x04,		0x05,		0x06,		0x07,		/* 01234567 */
	0x08,		0x09,		0x27,		0x26,		0x30 | S,	0x0b | S,	0x31 | S,	0x32 | S,	/* 89:;<=>? */
	0x1a,		0x1d,		0x2d,		0x2b,		0x1f,		0x12,		0x20,		0x21,		/* @ABCDEFG */
	0x22,		0x17,		0x23,		0x24,		0x25,		0x2f,		0x2e,		0x18,		/* HIJKLMNO */
	0x19,		0x10,		0x13,		0x1e,		0x14,		0x16,		0x2c,		0x11,		/* PQRSTUVW */
	0x2a,		0x15,		0x29,		0x1b,		0x0d,		0x28,		0x0c,		0x33 | S,	/* XYZ[\]^_ */
	0x0c | S,	0x1d,		0x2d,		0x2b,		0x1f,		0x12,		0x20,		0x21,		/* `abcdefg */
	0x22,		0x17,		0x23,		0x24,		0x25,		0x2f,		0x2e,		0x18,		/* hijklmno */
	0x19,		0x10,		0x13,		0x1e,		0x14,		0x16,		0x2c,		0x11,		/* pqrstuvw */
	0x2a,		0x15,		0x29,		0x1b | S,	0x0d | S,	0x28 | S,	0x1a | S,				/* xyz{|}~ */
};

/* half-width katakana U+FF61-U+FF9F (JIS X 0201 0xa1-0xdf) -> PC-98 key with KANA locked */
static const UINT8 s_kana[0x3f] = {
	0x31 | S,	0x1b | S,	0x28 | S,	0x30 | S,	0x32 | S,	0x0a | S,	0x03 | S,	/* ｡｢｣､･ｦｧ */
	0x12 | S,	0x04 | S,	0x05 | S,	0x06 | S,	0x07 | S,	0x08 | S,	0x09 | S,	0x29 | S,	/* ｨｩｪｫｬｭｮｯ */
	0x0d,		0x03,		0x12,		0x04,		0x05,		0x06,		0x14,		0x21,		/* ｰｱｲｳｴｵｶｷ */
	0x22,		0x27,		0x2d,		0x2a,		0x1f,		0x13,		0x19,		0x2b,		/* ｸｹｺｻｼｽｾｿ */
	0x10,		0x1d,		0x29,		0x11,		0x1e,		0x16,		0x17,		0x01,		/* ﾀﾁﾂﾃﾄﾅﾆﾇ */
	0x30,		0x24,		0x20,		0x2c,		0x02,		0x0c,		0x0b,		0x23,		/* ﾈﾉﾊﾋﾌﾍﾎﾏ */
	0x2e,		0x28,		0x32,		0x2f,		0x07,		0x08,		0x09,		0x18,		/* ﾐﾑﾒﾓﾔﾕﾖﾗ */
	0x25,		0x31,		0x26,		0x33,		0x0a,		0x15,		0x1a,		0x1b,		/* ﾘﾙﾚﾛﾜﾝﾞﾟ */
};

#undef S

static TYPESTEP *s_steps;
static NSUInteger s_nsteps;
static NSUInteger s_next;
static NSTimer *s_timer;
static BOOL s_shiftdown;	/* SHIFT pressed by the typing */

// ---- copy

void clipboard_copyscreen(void)
{
	[UIPasteboard generalPasteboard].string = textscreen_text();
}

@interface NP2ScreenTextController : UIViewController
@property (nonatomic, copy) NSString *text;
@end

@implementation NP2ScreenTextController

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.title = @"画面の文字";
	self.view.backgroundColor = [UIColor systemBackgroundColor];
	UITextView *view = [[UITextView alloc] initWithFrame:self.view.bounds];
	view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	view.editable = NO;
	view.selectable = YES;
	/* 80 columns: as small as needed to fit the sheet's width */
	view.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
	view.textContainerInset = UIEdgeInsetsMake(16, 8, 16, 8);
	view.textContainer.lineBreakMode = NSLineBreakByClipping;
	view.text = self.text;
	[self.view addSubview:view];

	__weak NP2ScreenTextController *weakSelf = self;
	self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithPrimaryAction:[UIAction actionWithTitle:@"すべてコピー" image:nil identifier:nil handler:^(UIAction *action) {
		(void)action;
		[UIPasteboard generalPasteboard].string = weakSelf.text;
		[weakSelf dismissViewControllerAnimated:YES completion:nil];
	}]];
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone primaryAction:[UIAction actionWithHandler:^(UIAction *action) {
		(void)action;
		[weakSelf dismissViewControllerAnimated:YES completion:nil];
	}] menu:nil];
}

@end

void clipboard_presentscreen(UIViewController *host)
{
	NP2ScreenTextController *controller = [NP2ScreenTextController new];
	controller.text = textscreen_text();
	UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:controller];
	nav.modalPresentationStyle = UIModalPresentationFormSheet;
	[host presentViewController:nav animated:YES completion:nil];
}

// ---- paste

static void add_step(NSMutableData *steps, UINT8 type, UINT8 code)
{
	TYPESTEP step = {type, code};
	[steps appendBytes:&step length:sizeof(step)];
}

/* What the keyboard can type: kana as half-width katakana (hiragana too),
 * full-width letters as ASCII, line breaks as \n. */
static NSString *typable_form(NSString *text)
{
	NSMutableString *str = [text mutableCopy];
	[str replaceOccurrencesOfString:@"\r\n" withString:@"\n" options:0 range:NSMakeRange(0, str.length)];
	[str replaceOccurrencesOfString:@"\r" withString:@"\n" options:0 range:NSMakeRange(0, str.length)];
	CFStringTransform((__bridge CFMutableStringRef)str, NULL, kCFStringTransformHiraganaKatakana, false);
	CFStringTransform((__bridge CFMutableStringRef)str, NULL, kCFStringTransformFullwidthHalfwidth, false);
	[str replaceOccurrencesOfString:@"¥" withString:@"\\" options:0 range:NSMakeRange(0, str.length)];	/* ¥ */
	[str replaceOccurrencesOfString:@"‾" withString:@"~" options:0 range:NSMakeRange(0, str.length)];	/* ‾ */
	return str;
}

/* The steps that type `text`; `skipped` gets the number of characters left out. */
static NSMutableData *steps_for(NSString *text, NSUInteger *skipped)
{
	NSMutableData *steps = [NSMutableData data];
	BOOL caps = keyinput_isactive(PC98KEY_CAPS);
	BOOL kana = keyinput_isactive(PC98KEY_KANA);
	const BOOL kanabefore = kana;
	BOOL shift = NO;
	NSString *str = typable_form(text);
	*skipped = 0;

	for (NSUInteger i = 0; i < str.length; i++) {
		unichar c = [str characterAtIndex:i];
		UINT8 key = NONE;
		BOOL wantkana = NO;
		if (c == '\n') {
			key = PC98KEY_RETURN;
		}
		else if (c == '\t') {
			key = PC98KEY_TAB;
		}
		else if (c >= 0x20 && c < 0x7f) {
			key = s_ascii[c - 0x20];
			BOOL capital = (c >= 'A' && c <= 'Z');
			if (capital || (c >= 'a' && c <= 'z')) {
				if (capital != caps) {	/* with CAPS locked, SHIFT types small letters */
					key |= 0x80;
				}
			}
		}
		else if (c >= 0xff61 && c <= 0xff9f) {
			key = s_kana[c - 0xff61];
			wantkana = YES;
		}
		if (key == NONE) {
			(*skipped)++;
			continue;
		}
		/* RETURN, TAB and SPACE type the same with KANA locked or not */
		if (key != PC98KEY_RETURN && key != PC98KEY_TAB && key != PC98KEY_SPACE && kana != wantkana) {
			add_step(steps, STEP_KANA, 0);
			kana = wantkana;
		}
		BOOL wantshift = (key & 0x80) != 0;
		if (shift != wantshift) {
			add_step(steps, wantshift ? STEP_DOWN : STEP_UP, PC98KEY_SHIFT);
			shift = wantshift;
		}
		add_step(steps, STEP_DOWN, key & 0x7f);
		add_step(steps, STEP_UP, key & 0x7f);
	}
	if (shift) {
		add_step(steps, STEP_UP, PC98KEY_SHIFT);
	}
	if (kana != kanabefore) {
		add_step(steps, STEP_KANA, 0);
	}
	return steps;
}

static void finish(void)
{
	[s_timer invalidate];
	s_timer = nil;
	free(s_steps);
	s_steps = NULL;
	s_nsteps = s_next = 0;
}

static void step(void)
{
	if (s_next >= s_nsteps) {
		finish();
		return;
	}
	TYPESTEP st = s_steps[s_next++];
	switch (st.type) {
		case STEP_DOWN:
			keystat_keydown(st.code);
			if (st.code == PC98KEY_SHIFT) {
				s_shiftdown = YES;
			}
			break;
		case STEP_UP:
			keystat_keyup(st.code);
			if (st.code == PC98KEY_SHIFT) {
				s_shiftdown = NO;
			}
			break;
		case STEP_KANA:
			keyinput_togglemodifier(PC98KEY_KANA);
			break;
	}
}

NSUInteger clipboard_type(NSString *text)
{
	clipboard_stoptyping();
	NSUInteger skipped;
	NSMutableData *steps = steps_for(text, &skipped);
	s_nsteps = steps.length / sizeof(TYPESTEP);
	if (s_nsteps == 0) {
		return skipped;
	}
	s_steps = malloc(steps.length);
	memcpy(s_steps, steps.bytes, steps.length);
	s_next = 0;
	s_timer = [NSTimer scheduledTimerWithTimeInterval:STEP_MS / 1000.0 repeats:YES block:^(NSTimer *timer) {
		(void)timer;
		step();
	}];
	return skipped;
}

BOOL clipboard_istyping(void)
{
	return s_timer != nil;
}

void clipboard_stoptyping(void)
{
	if (s_timer == nil) {
		return;
	}
	/* Let go of what the typing holds; the KANA lock stays as it is now. */
	if (s_next > 0 && s_steps[s_next - 1].type == STEP_DOWN) {
		keystat_keyup(s_steps[s_next - 1].code);
	}
	if (s_shiftdown) {
		keystat_keyup(PC98KEY_SHIFT);
		s_shiftdown = NO;
	}
	finish();
}

static NSUInteger untypable_count(NSString *text)
{
	NSUInteger skipped;
	(void)steps_for(text, &skipped);
	return skipped;
}

void clipboard_paste(UIViewController *host)
{
	NSString *text = [UIPasteboard generalPasteboard].string;
	if (text.length == 0) {
		UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"クリップボードに文字がありません"
		                                                               message:nil
		                                                        preferredStyle:UIAlertControllerStyleAlert];
		[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
		[host presentViewController:alert animated:YES completion:nil];
		return;
	}
	NSUInteger skipped = untypable_count(text);
	if (skipped == 0 && text.length <= ASK_LENGTH) {
		clipboard_type(text);
		return;
	}
	NSMutableArray<NSString *> *notes = [NSMutableArray array];
	if (text.length > ASK_LENGTH) {
		[notes addObject:[NSString stringWithFormat:@"%lu 文字あります。1 文字ずつキーを押して入力するので時間がかかります（≡ メニューで止められます）。",
		                  (unsigned long)text.length]];
	}
	if (skipped) {
		[notes addObject:[NSString stringWithFormat:@"漢字など、キーボードで打てない %lu 文字は入力しません。", (unsigned long)skipped]];
	}
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"貼り付けますか？"
	                                                               message:[notes componentsJoinedByString:@"\n"]
	                                                        preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
	[alert addAction:[UIAlertAction actionWithTitle:@"貼り付け" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
		(void)action;
		clipboard_type(text);
	}]];
	[host presentViewController:alert animated:YES completion:nil];
}
