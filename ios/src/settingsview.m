/**
 * @file	settingsview.m
 * @brief	In-app settings screen and the first-run guide
 *
 * App settings live in NSUserDefaults (shared with Settings.bundle, see
 * settings.m); emulator settings are written to np2cfg / np2oscfg and saved
 * to np21kai.cfg. Settings that the emulator reads only at reset say so.
 */

#include "compiler.h"
#include "settingsview.h"
#include "settings.h"
#include "keyinput.h"
#include "keybar.h"
#include "midiport.h"
#include "diskedit.h"
#include "lifecycle.h"

#import <CoreAudioKit/CoreAudioKit.h>
#include <pccore.h>
#include <np2.h>
#include <dosio.h>
#include <fdd/newdisk.h>
#include <fdd/diskdrv.h>
#include <diskimage/fddfile.h>
#include <generic/hostdrv.h>

extern void cmmidi_allnotesoff(void);

static NSNotificationName const kMidiSetupChanged = @"NP2MidiSetupChanged";

// ---- table model

typedef NS_ENUM(NSInteger, RowKind) {
	RowKindDetail,		/* value on the right, opens something */
	RowKindToggle,
	RowKindButton,
	RowKindChoice		/* checkmark when isOn */
};

@interface NP2Row : NSObject
@property (nonatomic) RowKind kind;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *(^detail)(void);
@property (nonatomic, copy) BOOL (^isOn)(void);
@property (nonatomic, copy) void (^setOn)(BOOL on);
@property (nonatomic, copy) void (^action)(UIViewController *controller);
@end

@implementation NP2Row
@end

@interface NP2Section : NSObject
@property (nonatomic, copy) NSString *header;
@property (nonatomic, copy) NSString *footer;
@property (nonatomic, copy) NSArray<NP2Row *> *rows;
@end

@implementation NP2Section
@end

static NP2Row *detail_row(NSString *title, NSString *(^detail)(void), void (^action)(UIViewController *))
{
	NP2Row *row = [NP2Row new];
	row.kind = RowKindDetail;
	row.title = title;
	row.detail = detail;
	row.action = action;
	return row;
}

static NP2Row *toggle_row(NSString *title, BOOL (^isOn)(void), void (^setOn)(BOOL))
{
	NP2Row *row = [NP2Row new];
	row.kind = RowKindToggle;
	row.title = title;
	row.isOn = isOn;
	row.setOn = setOn;
	return row;
}

static NP2Row *button_row(NSString *title, void (^action)(UIViewController *))
{
	NP2Row *row = [NP2Row new];
	row.kind = RowKindButton;
	row.title = title;
	row.action = action;
	return row;
}

static NP2Section *section(NSString *header, NSString *footer, NSArray<NP2Row *> *rows)
{
	NP2Section *s = [NP2Section new];
	s.header = header;
	s.footer = footer;
	s.rows = rows;
	return s;
}

// ---- generic table screen

@interface NP2TableViewController : UITableViewController
@property (nonatomic, copy) NSArray<NP2Section *> *(^build)(void);
@end

@implementation NP2TableViewController {
	NSArray<NP2Section *> *_sections;
}

- (instancetype)initWithTitle:(NSString *)title build:(NSArray<NP2Section *> *(^)(void))build
{
	self = [super initWithStyle:UITableViewStyleInsetGrouped];
	if (self) {
		self.title = title;
		_build = build;
	}
	return self;
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reload)
	                                             name:kMidiSetupChanged object:nil];
}

- (void)viewWillAppear:(BOOL)animated
{
	[super viewWillAppear:animated];
	[self reload];
}

- (void)reload
{
	_sections = self.build();
	[self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
	return (NSInteger)_sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)index
{
	return (NSInteger)_sections[(NSUInteger)index].rows.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)index
{
	return _sections[(NSUInteger)index].header;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)index
{
	return _sections[(NSUInteger)index].footer;
}

- (NP2Row *)rowAt:(NSIndexPath *)indexPath
{
	return _sections[(NSUInteger)indexPath.section].rows[(NSUInteger)indexPath.row];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
	NP2Row *row = [self rowAt:indexPath];
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
	cell.textLabel.text = row.title;
	cell.textLabel.numberOfLines = 0;
	switch (row.kind) {
	case RowKindDetail:
		cell.detailTextLabel.text = row.detail ? row.detail() : nil;
		cell.accessoryType = row.action ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
		cell.selectionStyle = row.action ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
		break;
	case RowKindToggle: {
		UISwitch *sw = [UISwitch new];
		sw.on = row.isOn();
		[sw addAction:[UIAction actionWithHandler:^(UIAction *action) {
			row.setOn(((UISwitch *)action.sender).on);
		}] forControlEvents:UIControlEventValueChanged];
		cell.accessoryView = sw;
		cell.selectionStyle = UITableViewCellSelectionStyleNone;
		break;
	}
	case RowKindButton:
		cell.textLabel.textColor = self.view.tintColor;
		break;
	case RowKindChoice:
		cell.accessoryType = row.isOn() ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
		break;
	}
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	NP2Row *row = [self rowAt:indexPath];
	if (row.kind != RowKindToggle && row.action) {
		row.action(self);
	}
}

@end

/* A list of choices; the current one is checked. */
static UIViewController *choice_screen(NSString *title, NSString *footer, NSArray<NSString *> *labels,
                                       NSInteger (^current)(void), void (^choose)(NSInteger index))
{
	__block __weak NP2TableViewController *weakScreen = nil;
	NP2TableViewController *screen = [[NP2TableViewController alloc] initWithTitle:title build:^NSArray<NP2Section *> *{
		NSMutableArray<NP2Row *> *rows = [NSMutableArray array];
		NSInteger selected = current();
		for (NSUInteger i = 0; i < labels.count; i++) {
			NP2Row *row = [NP2Row new];
			row.kind = RowKindChoice;
			row.title = labels[i];
			row.isOn = ^BOOL { return (NSInteger)i == selected; };
			row.action = ^(UIViewController *controller) {
				choose((NSInteger)i);
				[weakScreen reload];
				[controller.navigationController popViewControllerAnimated:YES];
			};
			[rows addObject:row];
		}
		return @[ section(nil, footer, rows) ];
	}];
	weakScreen = screen;
	return screen;
}

// ---- values

static NSString *const kAllPorts = @"*";
static NSString *const kNoPort = @"N/C";

static NSString *port_label(const char *selection)
{
	if (selection == NULL || selection[0] == '\0' || strcmp(selection, MIDIPORT_ALL) == 0) {
		return @"すべての機器";
	}
	if (milstr_cmp(selection, MIDIPORT_NC) == 0) {
		return @"なし";
	}
	return [NSString stringWithUTF8String:selection];
}

/* Choices for an MIDI port selection: all, none, then each device. A
 * selected device that is not connected now is kept in the list. */
static UIViewController *port_screen(NSString *title, BOOL sources, char *selection, size_t size)
{
	NSMutableArray<NSString *> *values = [NSMutableArray arrayWithObjects:kAllPorts, kNoPort, nil];
	midiport_list(sources, ^(const char *name) {
		[values addObject:[NSString stringWithUTF8String:name]];
	});
	NSString *current = [NSString stringWithUTF8String:selection];
	if (current.length && ![current isEqualToString:kAllPorts] && ![current isEqualToString:kNoPort] &&
	    ![values containsObject:current]) {
		[values addObject:current];
	}
	NSMutableArray<NSString *> *labels = [NSMutableArray array];
	for (NSString *value in values) {
		[labels addObject:port_label(value.UTF8String)];
	}
	NSString *footer = sources
		? @"「すべての機器」は接続中のすべての MIDI 機器から受け取ります。他のアプリからは「NP21 MIDI IN」に送れます。"
		: @"「すべての機器」は接続中のすべての MIDI 機器に送ります。他のアプリは「NP21 MIDI OUT」から受け取れます。";
	return choice_screen(title, footer, labels, ^NSInteger {
		NSString *now = [NSString stringWithUTF8String:selection];
		NSUInteger index = [values indexOfObject:now.length ? now : kAllPorts];
		return (index == NSNotFound) ? -1 : (NSInteger)index;
	}, ^(NSInteger index) {
		if (!sources) {
			cmmidi_allnotesoff();	/* don't leave notes hanging on the old device */
		}
		milstr_ncpy(selection, values[(NSUInteger)index].UTF8String, (int)size);
		midiport_refresh();
		settings_savenp2cfg();
	});
}

static UIViewController *latency_screen(NSString *title, NSString *key, NSArray<NSNumber *> *values, NSInteger standard)
{
	NSMutableArray<NSString *> *labels = [NSMutableArray array];
	for (NSNumber *value in values) {
		NSString *label = [NSString stringWithFormat:@"%@ ms", value];
		if (value.integerValue == 0) {
			label = @"0 ms（即時）";
		}
		else if (value.integerValue == standard) {
			label = [label stringByAppendingString:@"（標準）"];
		}
		[labels addObject:label];
	}
	return choice_screen(title, @"エミュレータ内の時刻に合わせて送受信するための遅延です。0 ms にすると即時になりますが、タイミングが最大約 18 ms ばらつきます。",
	                     labels, ^NSInteger {
		return (NSInteger)[values indexOfObject:@([[NSUserDefaults standardUserDefaults] integerForKey:key])];
	}, ^(NSInteger index) {
		[[NSUserDefaults standardUserDefaults] setInteger:values[(NSUInteger)index].integerValue forKey:key];
	});
}

static NSString *ms_label(NSString *key)
{
	NSInteger ms = [[NSUserDefaults standardUserDefaults] integerForKey:key];
	return ms ? [NSString stringWithFormat:@"%ld ms", (long)ms] : @"即時";
}

static const UINT s_multiples[] = {2, 4, 6, 8, 10, 12, 16, 20, 24, 32, 40, 48, 64};

static NSString *clock_label(UINT multiple)
{
	double mhz = (double)np2cfg.baseclock * multiple / 1e6;
	return [NSString stringWithFormat:@"×%u（%.1f MHz）", multiple, mhz];
}

static NSString *data_dir_hint(NSString *subdir)
{
	NSString *path = @"ファイル App →「このiPad内」/「このiPhone内」→ NP21 → sdlnp21kai";
	return subdir ? [path stringByAppendingFormat:@" → %@", subdir] : path;
}

static void open_files_app(void)
{
	/* shareddocuments:// opens the Files app at a local path */
	NSString *path = [NSFileManager defaultManager].currentDirectoryPath;
	NSURL *url = [NSURL URLWithString:[@"shareddocuments://" stringByAppendingString:
		[path stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet]]];
	[UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
}

// ---- new disk images

typedef struct {
	const char	*label;
	REG8		drv;		/* 0xff: floppy */
	const char	*ext;
} NEWDISKKIND;

static const NEWDISKKIND s_newdisks[] = {
	{"フロッピー（2HD）→ FDD1", 0xff, "d88"},
	{"ハードディスク → SCSI #0", 0x20, "hdd"},
	{"ハードディスク → SCSI #1", 0x21, "hdd"},
	{"ハードディスク → IDE #1", 0x00, "nhd"},
	{"ハードディスク → IDE #2", 0x01, "nhd"},
};

static const UINT s_hddsizes[] = {40, 80, 128, 256, 512};	/* MB; newdisk_vhd() allows up to 512 */

static NSString *new_disk_path(NSString *dir, NSString *ext)
{
	NSFileManager *fm = [NSFileManager defaultManager];
	[fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
	for (int n = 1; ; n++) {
		NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"new%d.%@", n, ext]];
		if (![fm fileExistsAtPath:path]) {
			return path;
		}
	}
}

static void create_disk(UIViewController *controller, const NEWDISKKIND *kind, UINT sizemb)
{
	BOOL floppy = (kind->drv == 0xff);
	NSString *path = new_disk_path(floppy ? @"fdd" : @"hdd", [NSString stringWithUTF8String:kind->ext]);
	REG8 drv = kind->drv;
	NSString *ext = [NSString stringWithUTF8String:kind->ext];

	UIAlertController *progress = [UIAlertController alertControllerWithTitle:@"作成しています…" message:path
	                                                           preferredStyle:UIAlertControllerStyleAlert];
	[controller presentViewController:progress animated:YES completion:nil];
	/* newdisk_* only write the file, so they can run off the main thread */
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		const char *fname = path.fileSystemRepresentation;
		if (floppy) {
			newdisk_fdd(fname, DISKTYPE_2HD << 4, "NP21");
		}
		else if ([ext isEqualToString:@"nhd"]) {
			newdisk_nhd(fname, sizemb);
		}
		else {
			newdisk_vhd(fname, sizemb);
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			[progress dismissViewControllerAnimated:YES completion:^{
				if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
					UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"作成できませんでした" message:nil
					                                                        preferredStyle:UIAlertControllerStyleAlert];
					[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
					[controller presentViewController:alert animated:YES completion:nil];
					return;
				}
				NSLog(@"settings: created %@", path);
				if (floppy) {
					diskdrv_setfdd(0, path.fileSystemRepresentation, 0);
				}
				else {
					keybar_sethdd(drv, path.fileSystemRepresentation);
				}
			}];
		});
	});
}

static UIViewController *new_disk_screen(void)
{
	return [[NP2TableViewController alloc] initWithTitle:@"新しいディスク" build:^NSArray<NP2Section *> *{
		NSMutableArray<NP2Row *> *rows = [NSMutableArray array];
		for (size_t i = 0; i < NELEMENTS(s_newdisks); i++) {
			const NEWDISKKIND *kind = &s_newdisks[i];
			[rows addObject:button_row([NSString stringWithUTF8String:kind->label], ^(UIViewController *controller) {
				if (kind->drv == 0xff) {
					create_disk(controller, kind, 0);
					return;
				}
				UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"容量" message:nil
				                                                        preferredStyle:UIAlertControllerStyleAlert];
				for (size_t j = 0; j < NELEMENTS(s_hddsizes); j++) {
					UINT size = s_hddsizes[j];
					[sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%u MB", size]
					                                          style:UIAlertActionStyleDefault
					                                        handler:^(UIAlertAction *action) {
						(void)action;
						create_disk(controller, kind, size);
					}]];
				}
				[sheet addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
				[controller presentViewController:sheet animated:YES completion:nil];
			})];
		}
		return @[ section(nil, @"空のディスクイメージを fdd/ または hdd/ に作り、ドライブに入れます。使う前に MS-DOS の FORMAT（ハードディスクは FORMAT /S など）で初期化してください。ハードディスクはリセット後に使えます。", rows) ];
	}];
}

// ---- license

@interface NP2TextViewController : UIViewController
@end

@implementation NP2TextViewController

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.title = @"ライセンス";
	UITextView *text = [[UITextView alloc] initWithFrame:self.view.bounds];
	text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	text.editable = NO;
	text.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
	text.textContainerInset = UIEdgeInsetsMake(16, 12, 16, 12);
	NSString *path = [[NSBundle mainBundle] pathForResource:@"Licenses" ofType:@"txt"];
	text.text = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil]
	                 : @"Licenses.txt が見つかりません。";
	[self.view addSubview:text];
}

@end

// ---- settings screen

static NSArray<NP2Section *> *settings_sections(void)
{
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	NSMutableArray<NP2Section *> *sections = [NSMutableArray array];

	[sections addObject:section(@"MIDI", @"MPU-PC98II の接続先です。Bluetooth MIDI 機器は「Bluetooth MIDI 機器」で接続すると一覧に出ます。", @[
		detail_row(@"出力先", ^NSString *{ return port_label(np2oscfg.mpu.mout); }, ^(UIViewController *c) {
			[c.navigationController pushViewController:port_screen(@"出力先", NO, np2oscfg.mpu.mout, sizeof(np2oscfg.mpu.mout)) animated:YES];
		}),
		detail_row(@"入力元", ^NSString *{ return port_label(np2oscfg.mpu.min); }, ^(UIViewController *c) {
			[c.navigationController pushViewController:port_screen(@"入力元", YES, np2oscfg.mpu.min, sizeof(np2oscfg.mpu.min)) animated:YES];
		}),
		detail_row(@"Bluetooth MIDI 機器", nil, ^(UIViewController *c) {
			[c.navigationController pushViewController:[CABTMIDICentralViewController new] animated:YES];
		}),
		detail_row(@"出力の遅延", ^NSString *{ return ms_label(kSettingMidiOutputLatency); }, ^(UIViewController *c) {
			[c.navigationController pushViewController:latency_screen(@"出力の遅延", kSettingMidiOutputLatency, @[ @0, @10, @20, @30, @50 ], 20) animated:YES];
		}),
		detail_row(@"入力の遅延", ^NSString *{ return ms_label(kSettingMidiInputLatency); }, ^(UIViewController *c) {
			[c.navigationController pushViewController:latency_screen(@"入力の遅延", kSettingMidiInputLatency, @[ @0, @20, @30, @50 ], 20) animated:YES];
		}),
	])];

	[sections addObject:section(@"キーボード", @"キーバーのキーボードボタンで出す画面のキーボードを選びます（ボタンの長押しでも切り替えられます）。PC-98 キーボードは PC-98 のキー配置そのもので、iOS のキーボードは文字どおりに入力します。ハードウェアキーボードの配列は、JIS ではキーの位置どおり、US では記号をキートップの文字どおりに入力します。振動と文字の大きな表示は、PC-98 キーボードを押したときのものです。長押しで連続入力は、押し続けたキーを 0.5 秒後から繰り返します（NP2 メニューの Key-repeat と同じ設定です）。", @[
		detail_row(@"画面のキーボード", ^NSString *{
			return settings_screenkeyboardtitle(settings_screenkeyboard());
		}, ^(UIViewController *c) {
			NSArray<NSString *> *identifiers = settings_screenkeyboards();
			NSMutableArray<NSString *> *labels = [NSMutableArray array];
			for (NSString *identifier in identifiers) {
				[labels addObject:settings_screenkeyboardtitle(identifier)];
			}
			[c.navigationController pushViewController:choice_screen(@"画面のキーボード", nil, labels, ^NSInteger {
				NSUInteger index = [identifiers indexOfObject:settings_screenkeyboard()];
				return (index == NSNotFound) ? -1 : (NSInteger)index;
			}, ^(NSInteger index) {
				[defaults setObject:identifiers[(NSUInteger)index] forKey:kSettingScreenKeyboard];
			}) animated:YES];
		}),
		toggle_row(@"キーを押したときに振動", ^BOOL { return settings_keyhaptics(); }, ^(BOOL on) {
			[defaults setBool:on forKey:kSettingKeyHaptics];
		}),
		toggle_row(@"押した文字を大きく表示", ^BOOL { return settings_keypreview(); }, ^(BOOL on) {
			[defaults setBool:on forKey:kSettingKeyPreview];
		}),
		toggle_row(@"長押しで連続入力", ^BOOL { return np2cfg.keyrepeat_enable != 0; }, ^(BOOL on) {
			np2cfg.keyrepeat_enable = on ? 1 : 0;
			settings_savenp2cfg();
		}),
		detail_row(@"ハードウェアキーボードの配列", ^NSString *{
			return ([defaults integerForKey:kSettingKeyboardLayout] == KEYLAYOUT_US) ? @"US" : @"JIS";
		}, ^(UIViewController *c) {
			[c.navigationController pushViewController:choice_screen(@"キーボード配列", nil, @[ @"JIS（日本語）", @"US（英語）" ], ^NSInteger {
				return [defaults integerForKey:kSettingKeyboardLayout];
			}, ^(NSInteger index) {
				[defaults setInteger:index forKey:kSettingKeyboardLayout];
			}) animated:YES];
		}),
	])];

	[sections addObject:section(@"ゲームコントローラ", @"十字キー（左スティック）と A / B ボタンの割り当てです。矢印キー・テンキーでは A が Z、B が X になります。ジョイスティック端子は、サウンドボード（PC-9801-26K / 86 など）のジョイスティック端子につないだものとして、トリガー 1 / 2 になります。ほかのボタンはいつも X がスペース、Y がリターン、L が SHIFT、R が CTRL、メニューが ESC、オプションが f·1 です。", @[
		detail_row(@"十字キーと A / B", ^NSString *{
			NSArray<NSString *> *labels = settings_gamepadmodes();
			NSInteger index = settings_gamepadmode();
			return (index >= 0 && index < (NSInteger)labels.count) ? labels[(NSUInteger)index] : @"";
		}, ^(UIViewController *c) {
			[c.navigationController pushViewController:choice_screen(@"十字キーと A / B", nil, settings_gamepadmodes(), ^NSInteger {
				return settings_gamepadmode();
			}, ^(NSInteger index) {
				[defaults setInteger:index forKey:kSettingGamepad];
			}) animated:YES];
		}),
	])];

	[sections addObject:section(@"折りたたみ（iPhone Duo）", @"半分開くと、PC-98 キーボードが出ます。縦向き（ノートパソコンのような持ち方）では上半分が画面、下半分がキーボードです。横向き（本のような持ち方）での配置をここで選べます。", @[
		detail_row(@"横向きで半分開いたとき", ^NSString *{
			NSArray<NSString *> *labels = settings_landscapefolds();
			NSInteger index = settings_landscapefold();
			return (index >= 0 && index < (NSInteger)labels.count) ? labels[(NSUInteger)index] : @"";
		}, ^(UIViewController *c) {
			[c.navigationController pushViewController:choice_screen(@"横向きで半分開いたとき", nil, settings_landscapefolds(), ^NSInteger {
				return settings_landscapefold();
			}, ^(NSInteger index) {
				[defaults setInteger:index forKey:kSettingLandscapeFold];
			}) animated:YES];
		}),
	])];

	[sections addObject:section(@"マウス", @"オンにすると、画面をタッチパッドのように使います。指でなぞるとマウスが動き、タップで左クリック、2 本指のタップで右クリック、少し押さえてから動かすとドラッグです。オフのときは、触れた所へマウスが動き、触れている間は左ボタンを押したままになります。≡ メニューからも切り替えられます。", @[
		toggle_row(@"画面をタッチパッドにする", ^BOOL { return settings_trackpad(); }, ^(BOOL on) {
			[defaults setBool:on forKey:kSettingTrackpad];
		}),
		detail_row(@"タッチパッドの速さ", ^NSString *{
			return [NSString stringWithFormat:@"%ld%%", (long)lround(settings_trackpadspeed() * 100)];
		}, ^(UIViewController *c) {
			NSArray<NSNumber *> *values = settings_trackpadspeeds();
			NSMutableArray<NSString *> *labels = [NSMutableArray array];
			for (NSNumber *value in values) {
				[labels addObject:[NSString stringWithFormat:(value.integerValue == 100) ? @"%@%%（標準）" : @"%@%%", value]];
			}
			[c.navigationController pushViewController:choice_screen(@"タッチパッドの速さ", @"100% では、指でなぞった長さだけマウスが動きます（速くなぞるとさらに遠くへ）。ソフトウェアやマウスドライバ側の速さも効きます。", labels, ^NSInteger {
				NSUInteger index = [values indexOfObject:@([defaults integerForKey:kSettingTrackpadSpeed])];
				return (index == NSNotFound) ? -1 : (NSInteger)index;
			}, ^(NSInteger index) {
				[defaults setInteger:values[(NSUInteger)index].integerValue forKey:kSettingTrackpadSpeed];
			}) animated:YES];
		}),
	])];

	[sections addObject:section(@"動作", @"CPU 速度はリセット後に反映されます。速すぎて実時間に追いつかないと、MIDI のタイミングが乱れます（画面に「速度」の警告が出ます）。バックグラウンドでの動作をオフにすると、ほかのアプリに切り替えたときに音と MIDI を止めます。", @[
		detail_row(@"CPU 速度", ^NSString *{ return clock_label(np2cfg.multiple); }, ^(UIViewController *c) {
			/* the standard choices, plus the current value if it is another one */
			NSMutableArray<NSNumber *> *values = [NSMutableArray array];
			for (size_t i = 0; i < NELEMENTS(s_multiples); i++) {
				[values addObject:@(s_multiples[i])];
			}
			if (![values containsObject:@(np2cfg.multiple)]) {
				[values addObject:@(np2cfg.multiple)];
				[values sortUsingSelector:@selector(compare:)];
			}
			NSMutableArray<NSString *> *labels = [NSMutableArray array];
			for (NSNumber *value in values) {
				[labels addObject:clock_label(value.unsignedIntValue)];
			}
			[c.navigationController pushViewController:choice_screen(@"CPU 速度", @"リセット後に反映されます。", labels, ^NSInteger {
				NSUInteger index = [values indexOfObject:@(np2cfg.multiple)];
				return (index == NSNotFound) ? -1 : (NSInteger)index;
			}, ^(NSInteger index) {
				np2cfg.multiple = values[(NSUInteger)index].unsignedIntValue;
				settings_savenp2cfg();
			}) animated:YES];
		}),
		toggle_row(@"バックグラウンドでも動作", ^BOOL { return settings_runinbackground(); }, ^(BOOL on) {
			[defaults setBool:on forKey:kSettingRunInBackground];
		}),
		toggle_row(@"前回の状態から再開", ^BOOL { return settings_resume(); }, ^(BOOL on) {
			[defaults setBool:on forKey:kSettingResume];
		}),
		toggle_row(@"速度が足りないときに警告", ^BOOL { return settings_showspeed(); }, ^(BOOL on) {
			[defaults setBool:on forKey:kSettingShowSpeed];
		}),
	])];

	[sections addObject:section(@"ホストドライブ（Z:）", [NSString stringWithFormat:@"%@ のファイルを DOS の Z: ドライブから読み書きできます。DOS 側に HOSTDRV の組み込みが必要です（「Z: を使えるようにする」で起動ディスクに組み込めます）。設定はリセット後に反映されます。", data_dir_hint(@"hostdrv")], @[
		button_row(@"Z: を使えるようにする", ^(UIViewController *c) {
			diskedit_setuphostdrive(c);
		}),
		toggle_row(@"ホストドライブを使う", ^BOOL { return np2cfg.hdrvenable != 0; }, ^(BOOL on) {
			np2cfg.hdrvenable = on ? 1 : 0;
			if (on) {
				if (np2cfg.hdrvroot[0] == '\0') {
					milstr_ncpy(np2cfg.hdrvroot, "hostdrv/", NELEMENTS(np2cfg.hdrvroot));
				}
				[[NSFileManager defaultManager] createDirectoryAtPath:[NSString stringWithUTF8String:np2cfg.hdrvroot]
				                          withIntermediateDirectories:YES attributes:nil error:nil];
			}
			settings_savenp2cfg();
		}),
		toggle_row(@"書き込み・削除を許可", ^BOOL { return (np2cfg.hdrvacc & (HDFMODE_WRITE | HDFMODE_DELETE)) != 0; }, ^(BOOL on) {
			np2cfg.hdrvacc = on ? (HDFMODE_READ | HDFMODE_WRITE | HDFMODE_DELETE) : HDFMODE_READ;
			settings_savenp2cfg();
		}),
	])];

	[sections addObject:section(@"ディスク", nil, @[
		button_row(@"ディスクの中身を見る・編集する", ^(UIViewController *c) {
			diskedit_present(c);
		}),
		detail_row(@"新しいディスクを作る", nil, ^(UIViewController *c) {
			[c.navigationController pushViewController:new_disk_screen() animated:YES];
		}),
		button_row(@"ファイル App でデータフォルダを開く", ^(UIViewController *c) {
			(void)c;
			open_files_app();
		}),
	])];

	NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
	[sections addObject:section(@"情報", @"BIOS や FONT の ROM、レコンポーザなどのソフトウェアはアプリに含まれていません。お持ちのものをデータフォルダに入れて使ってください。", @[
		detail_row(@"はじめに", nil, ^(UIViewController *c) {
			settingsview_presentguide(c);
		}),
		detail_row(@"ライセンス", nil, ^(UIViewController *c) {
			[c.navigationController pushViewController:[NP2TextViewController new] animated:YES];
		}),
		detail_row(@"バージョン", ^NSString *{ return version; }, nil),
	])];
	return sections;
}

static void post_midi_change(void)
{
	[[NSNotificationCenter defaultCenter] postNotificationName:kMidiSetupChanged object:nil];
}

void settingsview_present(UIViewController *host)
{
	midiport_onchange = post_midi_change;
	NP2TableViewController *root = [[NP2TableViewController alloc] initWithTitle:@"設定" build:^NSArray<NP2Section *> *{
		return settings_sections();
	}];
	UINavigationController *nav = [[NP2PausingNavigationController alloc] initWithRootViewController:root];
	root.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone primaryAction:[UIAction actionWithHandler:^(UIAction *action) {
		(void)action;
		[nav dismissViewControllerAnimated:YES completion:nil];
	}] menu:nil];
	nav.modalPresentationStyle = UIModalPresentationFormSheet;
	[host presentViewController:nav animated:YES completion:nil];
}

// ---- testing

void settingsview_debugtap(const char *title)
{
	UIViewController *top = UIApplication.sharedApplication.connectedScenes.allObjects.firstObject
		? ((UIWindowScene *)UIApplication.sharedApplication.connectedScenes.allObjects.firstObject).windows.firstObject.rootViewController
		: nil;
	while (top.presentedViewController) {
		top = top.presentedViewController;
	}
	if ([top isKindOfClass:[UINavigationController class]]) {
		top = ((UINavigationController *)top).topViewController;
	}
	if (![top isKindOfClass:[NP2TableViewController class]]) {
		NSLog(@"settings: no settings screen");
		return;
	}
	NP2TableViewController *screen = (NP2TableViewController *)top;
	NSString *wanted = [NSString stringWithUTF8String:title];
	for (NP2Section *sec in screen.build()) {
		for (NP2Row *row in sec.rows) {
			if (![row.title isEqualToString:wanted]) {
				continue;
			}
			if (row.kind == RowKindToggle) {
				row.setOn(!row.isOn());
				[screen reload];
			}
			else if (row.action) {
				row.action(screen);
			}
			NSLog(@"settings: tapped %@", wanted);
			return;
		}
	}
	NSLog(@"settings: no row %@", wanted);
}

void settingsview_debugnewdisk(int index, unsigned int sizemb)
{
	UIViewController *top = ((UIWindowScene *)UIApplication.sharedApplication.connectedScenes.allObjects.firstObject).windows.firstObject.rootViewController;
	while (top.presentedViewController) {
		top = top.presentedViewController;
	}
	if (index >= 0 && (size_t)index < NELEMENTS(s_newdisks)) {
		create_disk(top, &s_newdisks[index], sizemb);
	}
}

// ---- first-run guide

static BOOL has_bootable_disk(void)
{
	for (UINT i = 0; i < NELEMENTS(np2cfg.sasihdd); i++) {
		if (np2cfg.sasihdd[i][0] != '\0') {
			return TRUE;
		}
	}
	for (UINT i = 0; i < NELEMENTS(np2cfg.scsihdd); i++) {
		if (np2cfg.scsihdd[i][0] != '\0') {
			return TRUE;
		}
	}
	for (REG8 i = 0; i < 2; i++) {
		const OEMCHAR *name = fdd_diskname(i);
		if (name && name[0]) {
			return TRUE;
		}
	}
	return FALSE;
}

void settingsview_presentguide(UIViewController *host)
{
	NSString *message = [NSString stringWithFormat:
		@"PC-98 の起動ディスク（MS-DOS などが入ったハードディスクかフロッピーのイメージ）が必要です。\n\n"
		 "1. パソコンや iCloud Drive からディスクイメージを用意します。\n"
		 "2. ≡ メニューの「ハードディスク」か「FDD1 にディスクを入れる」で選びます（アプリのフォルダにコピーされます）。\n"
		 "3. ハードディスクはリセットすると起動します。\n\n"
		 "実機から吸い出した BIOS.ROM と FONT.ROM は %@ に入れてください。無くても互換 BIOS で起動しますが、文字（特に漢字）が正しく表示されないことがあります。\n\n"
		 "PC-98 の特殊キー（STOP、f·1〜f·10、GRPH など）は画面下（iPhone では右）のバーにあります。",
		data_dir_hint(nil)];
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"はじめに" message:message
	                                                        preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"ハードディスクを選ぶ…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
		(void)action;
		keybar_pickhdd(KEYBAR_HDD_AUTO);
	}]];
	[alert addAction:[UIAlertAction actionWithTitle:@"ファイル App で開く" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
		(void)action;
		open_files_app();
	}]];
	[alert addAction:[UIAlertAction actionWithTitle:@"閉じる" style:UIAlertActionStyleCancel handler:nil]];
	[host presentViewController:alert animated:YES completion:nil];
}

void settingsview_presentguideifneeded(UIViewController *host)
{
	if (!has_bootable_disk()) {
		settingsview_presentguide(host);
	}
}
