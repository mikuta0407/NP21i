/**
 * @file	kbdlayout.m
 * @brief	Layouts for the on-screen keyboard (kbdview.h)
 */

#include "compiler.h"
#include "kbdlayout.h"
#include "keyinput.h"

@implementation NP2Key

- (instancetype)initWithIdentifier:(NSString *)identifier kind:(NP2KeyKind)kind label:(NSString *)label codes:(NSArray<NSNumber *> *)codes
{
	self = [super init];
	if (self) {
		_identifier = [identifier copy];
		_kind = kind;
		_label = [label copy];
		_codes = [codes copy];
		_width = 1;
		_style = (kind == NP2KeyKindKey) ? NP2KeyStyleNormal : NP2KeyStyleDark;
	}
	return self;
}

+ (NP2Key *)key:(NSString *)identifier label:(NSString *)label code:(unsigned char)code
{
	return [[NP2Key alloc] initWithIdentifier:identifier kind:NP2KeyKindKey label:label codes:@[ @(code) ]];
}

+ (NP2Key *)modifier:(NSString *)identifier label:(NSString *)label code:(unsigned char)code
{
	return [[NP2Key alloc] initWithIdentifier:identifier kind:NP2KeyKindModifier label:label codes:@[ @(code) ]];
}

+ (NP2Key *)lock:(NSString *)identifier label:(NSString *)label code:(unsigned char)code
{
	return [[NP2Key alloc] initWithIdentifier:identifier kind:NP2KeyKindLock label:label codes:@[ @(code) ]];
}

+ (NP2Key *)chord:(NSString *)identifier label:(NSString *)label codes:(NSArray<NSNumber *> *)codes
{
	return [[NP2Key alloc] initWithIdentifier:identifier kind:NP2KeyKindChord label:label codes:codes];
}

+ (NP2Key *)spacer:(double)width
{
	return [[[NP2Key alloc] initWithIdentifier:@"" kind:NP2KeyKindSpacer label:@"" codes:@[]] width:width];
}

- (NP2Key *)width:(double)width
{
	_width = width;
	return self;
}

- (NP2Key *)shifted:(NSString *)label
{
	_shiftedLabel = [label copy];
	return self;
}

- (NP2Key *)kana:(NSString *)label
{
	_kanaLabel = [label copy];
	return self;
}

- (NP2Key *)spoken:(NSString *)name
{
	_spokenName = [name copy];
	return self;
}

- (NP2Key *)style:(NP2KeyStyle)style
{
	_style = style;
	return self;
}

@end

@implementation NP2KeyRow

+ (NP2KeyRow *)row:(NSArray<NP2Key *> *)keys
{
	return [self row:keys height:1];
}

+ (NP2KeyRow *)row:(NSArray<NP2Key *> *)keys height:(double)height
{
	NP2KeyRow *row = [[NP2KeyRow alloc] init];
	row->_keys = [keys copy];
	row->_height = height;
	double total = 0;
	for (NP2Key *key in keys) {
		total += key.width;
	}
	row->_totalWidth = total;
	return row;
}

@end

@implementation NP2KeyBlock

+ (NP2KeyBlock *)block:(NSString *)title rows:(NSArray<NP2KeyRow *> *)rows
{
	NP2KeyBlock *block = [[NP2KeyBlock alloc] init];
	block->_title = [title copy];
	block->_rows = [rows copy];
	for (NP2KeyRow *row in rows) {
		block->_width = MAX(block->_width, row.totalWidth);
		block->_height += row.height;
	}
	return block;
}

@end

// ---- PC-98

/* The character keys: position, label, SHIFT label, kana. */
typedef struct {
	UINT8		code;
	const char	*label;
	const char	*shifted;
	const char	*kana;
} CHARKEY;

static const CHARKEY s_numberrow[] = {
	{0x01, "1", "!", "ヌ"}, {0x02, "2", "\"", "フ"}, {0x03, "3", "#", "ア"}, {0x04, "4", "$", "ウ"},
	{0x05, "5", "%", "エ"}, {0x06, "6", "&", "オ"}, {0x07, "7", "'", "ヤ"}, {0x08, "8", "(", "ユ"},
	{0x09, "9", ")", "ヨ"}, {0x0a, "0", NULL, "ワ"}, {0x0b, "-", "=", "ホ"}, {0x0c, "^", "`", "ヘ"},
	{0x0d, "¥", "|", "ー"},
};

static const CHARKEY s_toprow[] = {
	{0x10, "Q", NULL, "タ"}, {0x11, "W", NULL, "テ"}, {0x12, "E", NULL, "イ"}, {0x13, "R", NULL, "ス"},
	{0x14, "T", NULL, "カ"}, {0x15, "Y", NULL, "ン"}, {0x16, "U", NULL, "ナ"}, {0x17, "I", NULL, "ニ"},
	{0x18, "O", NULL, "ラ"}, {0x19, "P", NULL, "セ"}, {0x1a, "@", "~", "゛"}, {0x1b, "[", "{", "゜"},
};

static const CHARKEY s_homerow[] = {
	{0x1d, "A", NULL, "チ"}, {0x1e, "S", NULL, "ト"}, {0x1f, "D", NULL, "シ"}, {0x20, "F", NULL, "ハ"},
	{0x21, "G", NULL, "キ"}, {0x22, "H", NULL, "ク"}, {0x23, "J", NULL, "マ"}, {0x24, "K", NULL, "ノ"},
	{0x25, "L", NULL, "リ"}, {0x26, ";", "+", "レ"}, {0x27, ":", "*", "ケ"}, {0x28, "]", "}", "ム"},
};

static const CHARKEY s_bottomrow[] = {
	{0x29, "Z", NULL, "ツ"}, {0x2a, "X", NULL, "サ"}, {0x2b, "C", NULL, "ソ"}, {0x2c, "V", NULL, "ヒ"},
	{0x2d, "B", NULL, "コ"}, {0x2e, "N", NULL, "ミ"}, {0x2f, "M", NULL, "モ"}, {0x30, ",", "<", "ネ"},
	{0x31, ".", ">", "ル"}, {0x32, "/", "?", "メ"}, {0x33, "_", NULL, "ロ"},
};

static NSString *str(const char *s)
{
	return s ? [NSString stringWithUTF8String:s] : nil;
}

static NSArray<NP2Key *> *char_keys(const CHARKEY *keys, size_t count)
{
	NSMutableArray<NP2Key *> *result = [NSMutableArray array];
	for (size_t i = 0; i < count; i++) {
		NSString *identifier = [NSString stringWithFormat:@"%02x", keys[i].code];
		[result addObject:[[[NP2Key key:identifier label:str(keys[i].label) code:keys[i].code]
			shifted:str(keys[i].shifted)] kana:str(keys[i].kana)]];
	}
	return result;
}

static NSArray<NP2Key *> *concat(NSArray<NSArray<NP2Key *> *> *parts)
{
	NSMutableArray<NP2Key *> *result = [NSMutableArray array];
	for (NSArray<NP2Key *> *part in parts) {
		[result addObjectsFromArray:part];
	}
	return result;
}

static NP2Key *dark(NSString *identifier, NSString *label, UINT8 code)
{
	return [[NP2Key key:identifier label:label code:code] style:NP2KeyStyleDark];
}

static NSArray<NP2Key *> *function_keys(int first, int count, double width)
{
	NSMutableArray<NP2Key *> *keys = [NSMutableArray array];
	for (int i = first; i < first + count; i++) {
		[keys addObject:[[dark([NSString stringWithFormat:@"f%d", i + 1], [NSString stringWithFormat:@"f·%d", i + 1], (UINT8)(PC98KEY_F1 + i))
			width:width] spoken:[NSString stringWithFormat:@"エフ%d", i + 1]]];
	}
	return keys;
}

static NP2Key *arrow(NSString *identifier, NSString *label, UINT8 code, NSString *spoken)
{
	return [dark(identifier, label, code) spoken:spoken];
}

static NP2KeyBlock *pc98_main(void)
{
	NP2Key *(^ret)(double) = ^NP2Key *(double width) {
		return [[dark(@"ret", @"RETURN", PC98KEY_RETURN) width:width] spoken:@"リターン"];
	};
	return [NP2KeyBlock block:@"メイン" rows:@[
		[NP2KeyRow row:concat(@[
			@[ dark(@"stop", @"STOP", PC98KEY_STOP), dark(@"copy", @"COPY", PC98KEY_COPY), [NP2Key spacer:0.5] ],
			function_keys(0, 5, 1.2),
			@[ [NP2Key spacer:0.5] ],
			function_keys(5, 5, 1.2),
		]) height:0.75],
		[NP2KeyRow row:concat(@[
			@[ dark(@"esc", @"ESC", PC98KEY_ESC) ],
			char_keys(s_numberrow, NELEMENTS(s_numberrow)),
			@[ [dark(@"bs", @"BS", PC98KEY_BS) spoken:@"バックスペース"] ],
		])],
		[NP2KeyRow row:concat(@[
			@[ [dark(@"tab", @"TAB", PC98KEY_TAB) width:1.5] ],
			char_keys(s_toprow, NELEMENTS(s_toprow)),
			@[ ret(1.5) ],
		])],
		[NP2KeyRow row:concat(@[
			@[ [NP2Key modifier:@"ctrl" label:@"CTRL" code:PC98KEY_CTRL], [NP2Key lock:@"caps" label:@"CAPS" code:PC98KEY_CAPS] ],
			char_keys(s_homerow, NELEMENTS(s_homerow)),
			@[ ret(1) ],
		])],
		[NP2KeyRow row:concat(@[
			@[ [[NP2Key modifier:@"shift" label:@"SHIFT" code:PC98KEY_SHIFT] width:1.5] ],
			char_keys(s_bottomrow, NELEMENTS(s_bottomrow)),
			@[ arrow(@"up", @"↑", PC98KEY_UP, @"上"),
			   [[NP2Key modifier:@"shift-r" label:@"SHIFT" code:PC98KEY_SHIFT] width:1.5] ],
		])],
		[NP2KeyRow row:@[
			[[NP2Key lock:@"kana" label:@"カナ" code:PC98KEY_KANA] width:1.25],
			[[NP2Key modifier:@"grph" label:@"GRPH" code:PC98KEY_GRPH] width:1.25],
			[dark(@"nfer", @"NFER", PC98KEY_NFER) width:1.5],
			[[[NP2Key key:@"space" label:@"" code:PC98KEY_SPACE] width:5.5] spoken:@"スペース"],
			[dark(@"xfer", @"XFER", PC98KEY_XFER) width:2],
			arrow(@"left", @"←", PC98KEY_LEFT, @"左"),
			arrow(@"down", @"↓", PC98KEY_DOWN, @"下"),
			[arrow(@"right", @"→", PC98KEY_RIGHT, @"右") width:1.5],
		]],
	]];
}

static NP2KeyBlock *pc98_edit(void)
{
	NP2Key *(^keypad)(NSString *, UINT8) = ^NP2Key *(NSString *label, UINT8 code) {
		return [[NP2Key key:[NSString stringWithFormat:@"kp%02x", code] label:label code:code]
			spoken:[@"テンキー " stringByAppendingString:label]];
	};
	NSMutableArray<NP2Key *> *vf = [NSMutableArray array];
	for (int i = 0; i < 5; i++) {
		[vf addObject:[[dark([NSString stringWithFormat:@"vf%d", i + 1], [NSString stringWithFormat:@"vf·%d", i + 1], (UINT8)(PC98KEY_VF1 + i))
			width:1.5] spoken:[NSString stringWithFormat:@"ブイエフ%d", i + 1]]];
	}
	return [NP2KeyBlock block:@"編集・テンキー" rows:@[
		[NP2KeyRow row:vf height:0.75],
		[NP2KeyRow row:@[
			[[dark(@"rollup", @"ROLL UP", PC98KEY_ROLLUP) width:1.5] spoken:@"ロールアップ"],
			[[dark(@"rolldown", @"ROLL DOWN", PC98KEY_ROLLDOWN) width:1.5] spoken:@"ロールダウン"],
			[NP2Key spacer:0.5],
			[dark(@"home", @"HOME", PC98KEY_HOMECLR) spoken:@"ホーム クリア"],
			dark(@"help", @"HELP", PC98KEY_HELP),
			keypad(@"-", 0x40), keypad(@"/", 0x41),
		]],
		[NP2KeyRow row:@[
			[dark(@"ins", @"INS", PC98KEY_INS) width:1.5],
			[dark(@"del", @"DEL", PC98KEY_DEL) width:1.5],
			[NP2Key spacer:0.5],
			keypad(@"7", 0x42), keypad(@"8", 0x43), keypad(@"9", 0x44), keypad(@"*", 0x45),
		]],
		[NP2KeyRow row:@[
			[dark(@"esc", @"ESC", PC98KEY_ESC) width:0.75], [arrow(@"up", @"↑", PC98KEY_UP, @"上") width:1.5],
			[dark(@"tab", @"TAB", PC98KEY_TAB) width:0.75],
			[NP2Key spacer:0.5],
			keypad(@"4", 0x46), keypad(@"5", 0x47), keypad(@"6", 0x48), keypad(@"+", 0x49),
		]],
		[NP2KeyRow row:@[
			[arrow(@"left", @"←", PC98KEY_LEFT, @"左") width:1.5],
			[arrow(@"right", @"→", PC98KEY_RIGHT, @"右") width:1.5],
			[NP2Key spacer:0.5],
			keypad(@"1", 0x4a), keypad(@"2", 0x4b), keypad(@"3", 0x4c), keypad(@"=", 0x4d),
		]],
		[NP2KeyRow row:@[
			[NP2Key spacer:0.75], [arrow(@"down", @"↓", PC98KEY_DOWN, @"下") width:1.5], [NP2Key spacer:0.75],
			[NP2Key spacer:0.5],
			keypad(@"0", 0x4e), keypad(@",", 0x4f), keypad(@".", 0x50), [NP2Key spacer:1],
		]],
	]];
}

/* For games: a large cross and the keys games mostly ask for, one block. */
static NP2KeyBlock *game_block(void)
{
	NP2Key *(^action)(NSString *, NSString *, UINT8, NSString *) = ^NP2Key *(NSString *identifier, NSString *label, UINT8 code, NSString *spoken) {
		return [[[[NP2Key key:identifier label:label code:code] style:NP2KeyStyleAccent] width:2.75] spoken:spoken];
	};
	NP2Key *(^digit)(int) = ^NP2Key *(int n) {
		return [NP2Key key:[NSString stringWithFormat:@"%02x", n] label:[NSString stringWithFormat:@"%d", n] code:(UINT8)n];
	};
	return [NP2KeyBlock block:@"ゲーム" rows:@[
		[NP2KeyRow row:concat(@[
			@[ [dark(@"esc", @"ESC", PC98KEY_ESC) width:1.5], [dark(@"stop", @"STOP", PC98KEY_STOP) width:1.5], [NP2Key spacer:0.5] ],
			function_keys(0, 5, 1.3),
		]) height:0.75],
		[NP2KeyRow row:@[
			[NP2Key spacer:1], [arrow(@"up", @"↑", PC98KEY_UP, @"上") width:2], [NP2Key spacer:1], [NP2Key spacer:0.5],
			[[NP2Key modifier:@"shift" label:@"SHIFT" code:PC98KEY_SHIFT] width:2.75],
			[[NP2Key modifier:@"ctrl" label:@"CTRL" code:PC98KEY_CTRL] width:2.75],
		]],
		[NP2KeyRow row:@[
			[arrow(@"left", @"←", PC98KEY_LEFT, @"左") width:2], [arrow(@"right", @"→", PC98KEY_RIGHT, @"右") width:2], [NP2Key spacer:0.5],
			action(@"29", @"Z", 0x29, @"ゼット"), action(@"2a", @"X", 0x2a, @"エックス"),
		]],
		[NP2KeyRow row:@[
			[NP2Key spacer:1], [arrow(@"down", @"↓", PC98KEY_DOWN, @"下") width:2], [NP2Key spacer:1], [NP2Key spacer:0.5],
			action(@"space", @"SPACE", PC98KEY_SPACE, @"スペース"), action(@"ret", @"RETURN", PC98KEY_RETURN, @"リターン"),
		]],
		[NP2KeyRow row:@[
			digit(1), digit(2), digit(3), digit(4), digit(5), [NP2Key spacer:0.5],
			[[NP2Key key:@"15" label:@"Y" code:0x15] width:1.5], [[NP2Key key:@"2e" label:@"N" code:0x2e] width:1.5],
			[[dark(@"bs", @"BS", PC98KEY_BS) width:1.5] spoken:@"バックスペース"],
		]],
	]];
}

// ---- Recomposer (step input)

/* Recomposer V3.0's track editor (F3 EDIT): a note is typed as its name,
 * then + (sharp) or - (flat), then the octave (kept from the last note):
 * "C", "F+5", "B-". RETURN enters it with the last length, f·1-f·10 with a
 * length (whole note ... 32nd). Digits alone are a key number. Letters and
 * CTRL + letters (shown as ^N) are the editing commands (HELP lists them). */

static NP2Key *command(NSString *identifier, NSString *label, NSString *letter, UINT8 code, NSString *spoken)
{
	return [[[[[NP2Key key:identifier label:label code:code] shifted:letter] style:NP2KeyStyleDark] width:1.08] spoken:spoken];
}

static NP2Key *ctrl_command(NSString *identifier, NSString *label, NSString *letter, UINT8 code, NSString *spoken)
{
	return [[[[[NP2Key chord:identifier label:label codes:@[ @(PC98KEY_CTRL), @(code) ]] shifted:[@"^" stringByAppendingString:letter]]
		style:NP2KeyStyleDark] width:1.08] spoken:spoken];
}

static NP2KeyBlock *rcp_notes(void)
{
	/* f·1-f·10 as Recomposer shows them: whole, dotted half, half ... 32nd */
	static const char *const lengths[10][2] = {
		{"全", "全音符"}, {"2分.", "付点2分音符"}, {"2分", "2分音符"}, {"4分.", "付点4分音符"}, {"4分", "4分音符"},
		{"8分.", "付点8分音符"}, {"8分", "8分音符"}, {"16分.", "付点16分音符"}, {"16分", "16分音符"}, {"32分", "32分音符"},
	};
	NSMutableArray<NP2Key *> *lengthKeys = [NSMutableArray array];
	for (int i = 0; i < 10; i++) {
		if (i == 5) {
			[lengthKeys addObject:[NP2Key spacer:0.3]];
		}
		[lengthKeys addObject:[[[[[NP2Key key:[NSString stringWithFormat:@"f%d", i + 1] label:str(lengths[i][0]) code:(UINT8)(PC98KEY_F1 + i)]
			shifted:[NSString stringWithFormat:@"f·%d", i + 1]] style:NP2KeyStyleAccent] width:1.18] spoken:str(lengths[i][1])]];
	}

	/* C D E F G A B, as on a staff */
	static const struct { const char *name; const char *letter; UINT8 code; } notes[] = {
		{"ド", "C", 0x2b}, {"レ", "D", 0x1f}, {"ミ", "E", 0x12}, {"ファ", "F", 0x20},
		{"ソ", "G", 0x21}, {"ラ", "A", 0x1d}, {"シ", "B", 0x2d},
	};
	NSMutableArray<NP2Key *> *noteKeys = [NSMutableArray array];
	for (size_t i = 0; i < NELEMENTS(notes); i++) {
		[noteKeys addObject:[[[NP2Key key:[NSString stringWithFormat:@"%02x", notes[i].code] label:str(notes[i].name) code:notes[i].code]
			shifted:str(notes[i].letter)] width:1.4]];
	}
	[noteKeys addObject:[NP2Key spacer:0.3]];
	[noteKeys addObject:[[[NP2Key chord:@"sharp" label:@"♯" codes:@[ @(PC98KEY_SHIFT), @0x26 ]] shifted:@"+"] spoken:@"シャープ"]];
	[noteKeys addObject:[[[NP2Key key:@"0b" label:@"♭" code:0x0b] shifted:@"-"] spoken:@"フラット"]];

	NSMutableArray<NP2Key *> *digits = [NSMutableArray array];
	for (int n = 1; n <= 10; n++) {
		UINT8 code = (UINT8)(n % 10 == 0 ? 0x0a : n);
		[digits addObject:[[NP2Key key:[NSString stringWithFormat:@"%02x", code] label:[NSString stringWithFormat:@"%d", n % 10] code:code]
			width:1.06]];
	}
	[digits addObject:[NP2Key spacer:0.3]];
	[digits addObject:[[dark(@"bs", @"BS", PC98KEY_BS) width:1.2] spoken:@"バックスペース"]];

	return [NP2KeyBlock block:@"音符" rows:@[
		[NP2KeyRow row:lengthKeys height:0.9],
		[NP2KeyRow row:noteKeys],
		[NP2KeyRow row:digits],
		[NP2KeyRow row:@[
			[dark(@"esc", @"ESC", PC98KEY_ESC) width:1.5],
			[[[dark(@"tab", @"和音", PC98KEY_TAB) shifted:@"TAB"] width:1.5] spoken:@"和音入力"],
			[[[[NP2Key chord:@"measend" label:@"小節線" codes:@[ @(PC98KEY_SHIFT), @0x27 ]] shifted:@"*"] width:1.5] spoken:@"小節線"],
			[[[[NP2Key key:@"ret" label:@"入力" code:PC98KEY_RETURN] shifted:@"RETURN"] style:NP2KeyStyleAccent] width:7.6],
		]],
	]];
}

static NP2KeyBlock *rcp_edit(void)
{
	return [NP2KeyBlock block:@"編集" rows:@[
		[NP2KeyRow row:@[
			[[dark(@"help", @"HELP", PC98KEY_HELP) width:1.08] spoken:@"ヘルプ"],
			ctrl_command(@"ctrl-t", @"先頭", @"T", 0x14, @"先頭の小節"),
			ctrl_command(@"ctrl-b", @"前小節", @"B", 0x2d, @"前の小節"),
			ctrl_command(@"ctrl-n", @"次小節", @"N", 0x2e, @"次の小節"),
			[[dark(@"stop", @"STOP", PC98KEY_STOP) width:1.08] spoken:@"ストップ"],
		] height:0.9],
		[NP2KeyRow row:@[
			command(@"cmd-r", @"コピー", @"R", 0x13, @"コピー"),
			command(@"cmd-y", @"貼付", @"Y", 0x15, @"貼り付け"),
			command(@"cmd-k", @"削除", @"K", 0x24, @"削除"),
			command(@"cmd-i", @"挿入", @"I", 0x17, @"挿入"),
			command(@"cmd-u", @"取消", @"U", 0x16, @"取り消し"),
		]],
		[NP2KeyRow row:@[
			[[[dark(@"rollup", @"前頁", PC98KEY_ROLLUP) shifted:@"R.UP"] width:1.08] spoken:@"ロールアップ"],
			[arrow(@"up", @"↑", PC98KEY_UP, @"上") width:1.08],
			[[[dark(@"rolldown", @"次頁", PC98KEY_ROLLDOWN) shifted:@"R.DN"] width:1.08] spoken:@"ロールダウン"],
			command(@"cmd-m", @"小節再生", @"M", 0x2f, @"小節を再生"),
			command(@"cmd-p", @"位置再生", @"P", 0x19, @"カーソル位置から再生"),
		]],
		[NP2KeyRow row:@[
			[arrow(@"left", @"←", PC98KEY_LEFT, @"左") width:1.08],
			[arrow(@"down", @"↓", PC98KEY_DOWN, @"下") width:1.08],
			[arrow(@"right", @"→", PC98KEY_RIGHT, @"右") width:1.08],
			command(@"cmd-j", @"全体再生", @"J", 0x23, @"トラックを再生"),
			command(@"cmd-h", @"消去", @"H", 0x22, @"消去"),
		]],
	]];
}

@implementation NP2KeyboardLayout

+ (NP2KeyboardLayout *)layout:(NSString *)identifier title:(NSString *)title blocks:(NSArray<NP2KeyBlock *> *)blocks
{
	NP2KeyboardLayout *layout = [[NP2KeyboardLayout alloc] init];
	layout->_identifier = [identifier copy];
	layout->_title = [title copy];
	layout->_blocks = [blocks copy];
	return layout;
}

+ (NSArray<NP2KeyboardLayout *> *)allLayouts
{
	static NSArray<NP2KeyboardLayout *> *layouts;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		layouts = @[ [self pc98Layout], [self recomposerLayout], [self gameLayout] ];
	});
	return layouts;
}

+ (NP2KeyboardLayout *)layoutWithIdentifier:(NSString *)identifier
{
	for (NP2KeyboardLayout *layout in [self allLayouts]) {
		if ([layout.identifier isEqualToString:identifier]) {
			return layout;
		}
	}
	return nil;
}

+ (NP2KeyboardLayout *)pc98Layout
{
	return [self layout:@"pc98" title:@"PC-98 キーボード" blocks:@[ pc98_main(), pc98_edit() ]];
}

+ (NP2KeyboardLayout *)recomposerLayout
{
	return [self layout:@"rcp" title:@"レコンポーザ（ステップ入力）" blocks:@[ rcp_notes(), rcp_edit() ]];
}

+ (NP2KeyboardLayout *)gameLayout
{
	return [self layout:@"game" title:@"ゲーム用キーボード" blocks:@[ game_block() ]];
}

@end
