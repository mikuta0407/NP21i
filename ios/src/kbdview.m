/**
 * @file	kbdview.m
 * @brief	On-screen keyboard drawn by the app (any NP2KeyboardLayout)
 *
 * Modelled on mRemote's laptop deck: the keys are drawn by cap views that
 * take no touches; this view does all the touch handling, so multi-touch
 * works across keys. Keys are sent with keyinput_down() / keyinput_up(); held
 * keys are repeated by NP2kai's key repeat, on by default on iOS (patch 0009).
 *
 * Modifiers (SHIFT / CTRL / GRPH) are held while touched. Tapped alone they
 * latch for the next key, like the key bar's; tapping a latched one again
 * releases it. CAPS / KANA toggle; with KANA on, the keys show kana.
 */

#include "compiler.h"
#include "kbdview.h"
#include "keyinput.h"

static const CGFloat kPadding = 4;
static const CGFloat kKeyGap = 4;
static const CGFloat kBlockGapUnits = 0.5;
static const CGFloat kTabsHeight = 30;
static const CGFloat kMinUnitWidth = 30;	/* blocks side by side only when the keys are this wide */
static const CGFloat kMinRowHeight = 22;
static const CGFloat kMaxRowHeight = 54;
static const CGFloat kMaxFillAspect = 1.6;	/* filling the height: row height / key width */

typedef NS_ENUM(NSInteger, CapState) {
	CapStateIdle,
	CapStatePressed,
	CapStateActive		/* modifier held or latched, lock on */
};

/* One key cap. Draws only; the keyboard view handles the touches and stands
 * in for it to VoiceOver through onActivate. */
@interface NP2KeyCap : UIView
@property (nonatomic, readonly) NP2Key *key;
@property (nonatomic, readonly) NSInteger block;
@property (nonatomic) CapState state;
@property (nonatomic) BOOL kana;
@property (nonatomic) NSInteger touches;
@property (nonatomic, copy) void (^onActivate)(NP2KeyCap *cap);
/* What the cap shows now (kana when KANA is on). */
- (NSString *)shownLabel;
@end

@implementation NP2KeyCap {
	CAShapeLayer *_capLayer;
	UILabel *_label;
	UILabel *_shiftedLabel;
	CGRect _labelArea;
}

- (instancetype)initWithKey:(NP2Key *)key block:(NSInteger)block
{
	self = [super initWithFrame:CGRectZero];
	if (self) {
		_key = key;
		_block = block;
		self.userInteractionEnabled = NO;
		_capLayer = [CAShapeLayer layer];
		[self.layer addSublayer:_capLayer];

		_label = [[UILabel alloc] init];
		_label.textColor = UIColor.whiteColor;
		_label.textAlignment = NSTextAlignmentCenter;
		_label.adjustsFontSizeToFitWidth = YES;
		_label.minimumScaleFactor = 0.5;
		_label.numberOfLines = 1;
		[self addSubview:_label];

		_shiftedLabel = [[UILabel alloc] init];
		_shiftedLabel.textColor = [UIColor colorWithWhite:0.72 alpha:1];
		_shiftedLabel.textAlignment = NSTextAlignmentLeft;
		[self addSubview:_shiftedLabel];

		self.isAccessibilityElement = YES;
		self.accessibilityLabel = key.spokenName ?: key.label;
		self.accessibilityTraits = UIAccessibilityTraitKeyboardKey;
		self.accessibilityIdentifier = [@"key-" stringByAppendingString:key.identifier];
		[self applyLabels];
		[self applyState];
	}
	return self;
}

- (BOOL)accessibilityActivate
{
	if (self.onActivate) {
		self.onActivate(self);
	}
	return YES;
}

- (void)setState:(CapState)state
{
	if (state != _state) {
		_state = state;
		[self applyState];
	}
}

- (void)setKana:(BOOL)kana
{
	if (kana != _kana) {
		_kana = kana;
		[self applyLabels];
		[self setNeedsLayout];
	}
}

- (NSString *)shownLabel
{
	return _label.text;
}

- (void)applyLabels
{
	BOOL kana = _kana && _key.kanaLabel;
	_label.text = kana ? _key.kanaLabel : _key.label;
	_shiftedLabel.text = kana ? nil : _key.shiftedLabel;
	_shiftedLabel.hidden = (_shiftedLabel.text == nil);
}

- (void)applyState
{
	UIColor *fill;
	switch (_state) {
		case CapStatePressed:
			fill = [UIColor colorWithWhite:0.55 alpha:1];
			break;
		case CapStateActive:
			fill = UIColor.systemOrangeColor;
			break;
		default:
			switch (_key.style) {
				case NP2KeyStyleDark:
					fill = [UIColor colorWithWhite:0.19 alpha:1];
					break;
				case NP2KeyStyleAccent:
					fill = [UIColor colorWithRed:0.10 green:0.30 blue:0.55 alpha:1];
					break;
				default:
					fill = [UIColor colorWithWhite:0.30 alpha:1];
					break;
			}
			break;
	}
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	_capLayer.fillColor = fill.CGColor;
	[CATransaction commit];
	if (_key.kind == NP2KeyKindModifier || _key.kind == NP2KeyKindLock) {
		self.accessibilityValue = (_state == CapStateActive) ? @"オン" : @"オフ";
	}
}

/* The rectangles the key covers, in the superview's coordinates, one per
 * row. Parts in consecutive rows are joined across the gap, which turns
 * RETURN into one inverted L. */
- (void)setParts:(NSArray<NSValue *> *)parts
{
	CGRect frame = parts[0].CGRectValue;
	for (NSValue *part in parts) {
		frame = CGRectUnion(frame, part.CGRectValue);
	}
	self.frame = frame;
	CGFloat radius = MIN(5, frame.size.height / 6);
	UIBezierPath *path = [UIBezierPath bezierPath];
	for (NSUInteger i = 0; i < parts.count; i++) {
		CGRect rect = CGRectOffset(parts[i].CGRectValue, -frame.origin.x, -frame.origin.y);
		if (i + 1 < parts.count) {
			/* down into the next part, past its rounded corners */
			CGFloat next = CGRectGetMinY(parts[i + 1].CGRectValue) - frame.origin.y;
			rect.size.height = next - rect.origin.y + radius * 2;
		}
		[path appendPath:[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:radius]];
	}
	_capLayer.path = path.CGPath;
	_labelArea = CGRectOffset(parts[0].CGRectValue, -frame.origin.x, -frame.origin.y);
	[self setNeedsLayout];
}

- (void)layoutSubviews
{
	[super layoutSubviews];
	CGRect area = CGRectIsEmpty(_labelArea) ? self.bounds : _labelArea;
	CGFloat size = MIN(area.size.height * 0.42, 18);
	BOOL word = (_label.text.length > 2);
	_label.font = [UIFont systemFontOfSize:word ? size * 0.72 : size weight:UIFontWeightMedium];
	_shiftedLabel.font = [UIFont systemFontOfSize:size * 0.62];
	if (_shiftedLabel.hidden) {
		_label.frame = CGRectInset(area, 2, 1);
	}
	else {
		CGFloat half = area.size.height / 2;
		_shiftedLabel.frame = CGRectMake(area.origin.x + 4, area.origin.y + 1, area.size.width - 6, half);
		_label.frame = CGRectMake(area.origin.x + 2, area.origin.y + half * 0.7, area.size.width - 4, half * 1.2);
	}
}

@end

// ---- the keyboard

@implementation NP2KeyboardView {
	NSMutableArray<NP2KeyCap *> *_caps;
	NSMutableArray<NSValue *> *_hitFrames;		/* parallel to _hitCaps */
	NSMutableArray<NP2KeyCap *> *_hitCaps;
	UISegmentedControl *_tabs;
	UISegmentedControl *_switcher;
	NSInteger _page;
	NSMapTable<UITouch *, NP2KeyCap *> *_touches;
	int _keyCount[0x80];		/* fingers holding each key code */
	int _modifierCount[0x80];	/* fingers holding each modifier */
	BOOL _modifierUsed[0x80];	/* another key was pressed while it was held */
	UIImpactFeedbackGenerator *_haptics;
	NSMapTable<NP2KeyCap *, UIView *> *_previews;	/* shown above pressed keys */
}

- (instancetype)initWithLayout:(NP2KeyboardLayout *)layout
{
	self = [super initWithFrame:CGRectZero];
	if (self) {
		self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1];
		self.multipleTouchEnabled = YES;
		self.accessibilityIdentifier = @"screen-keyboard";
		_touches = [NSMapTable strongToStrongObjectsMapTable];
		_haptics = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
		_previews = [NSMapTable strongToStrongObjectsMapTable];
		_hapticFeedback = YES;
		_keyPreview = YES;
		_tabs = [[UISegmentedControl alloc] init];
		_tabs.selectedSegmentTintColor = [UIColor colorWithWhite:0.40 alpha:1];
		[_tabs setTitleTextAttributes:@{ NSForegroundColorAttributeName: UIColor.whiteColor } forState:UIControlStateNormal];
		[_tabs addTarget:self action:@selector(tabChanged) forControlEvents:UIControlEventValueChanged];
		[self addSubview:_tabs];
		_switcher = [[UISegmentedControl alloc] init];
		_switcher.selectedSegmentTintColor = [UIColor colorWithRed:0.10 green:0.30 blue:0.55 alpha:1];
		[_switcher setTitleTextAttributes:@{ NSForegroundColorAttributeName: UIColor.whiteColor,
		                                     NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightMedium] } forState:UIControlStateNormal];
		[_switcher addTarget:self action:@selector(switcherChanged) forControlEvents:UIControlEventValueChanged];
		_switcher.hidden = YES;
		[self addSubview:_switcher];
		self.layout = layout;
	}
	return self;
}

- (void)setSwitchTitles:(NSArray<NSString *> *)titles
{
	_switchTitles = [titles copy];
	[_switcher removeAllSegments];
	[titles enumerateObjectsUsingBlock:^(NSString *title, NSUInteger index, BOOL *stop) {
		(void)stop;
		[self->_switcher insertSegmentWithTitle:title atIndex:index animated:NO];
	}];
	_switcher.selectedSegmentIndex = _switchIndex;
	[self setNeedsLayout];
}

- (void)setSwitchIndex:(NSInteger)index
{
	_switchIndex = index;
	_switcher.selectedSegmentIndex = index;
}

- (void)switcherChanged
{
	NSInteger index = _switcher.selectedSegmentIndex;
	_switcher.selectedSegmentIndex = _switchIndex;	/* until the owner switches */
	if (index != _switchIndex && self.onSwitch) {
		self.onSwitch(index);
	}
}

/* A row at the top for the switcher and / or the tabs. */
- (BOOL)hasTopRowForWidth:(CGFloat)width
{
	return _switchTitles.count > 0 || [self pagedForWidth:width];
}

- (void)setFillsHeight:(BOOL)fillsHeight
{
	if (fillsHeight != _fillsHeight) {
		_fillsHeight = fillsHeight;
		[self setNeedsLayout];
	}
}

- (void)setLayout:(NP2KeyboardLayout *)layout
{
	if (layout == _layout) {
		return;
	}
	[self releaseAll];
	_layout = layout;
	for (NP2KeyCap *cap in _caps) {
		[cap removeFromSuperview];
	}
	_caps = [NSMutableArray array];
	__weak NP2KeyboardView *weakSelf = self;
	[layout.blocks enumerateObjectsUsingBlock:^(NP2KeyBlock *block, NSUInteger index, BOOL *stop) {
		(void)stop;
		NSMutableSet<NSString *> *previousRow = [NSMutableSet set];
		for (NP2KeyRow *row in block.rows) {
			NSMutableSet<NSString *> *thisRow = [NSMutableSet set];
			for (NP2Key *key in row.keys) {
				if (key.kind == NP2KeyKindSpacer) {
					continue;
				}
				[thisRow addObject:key.identifier];
				if ([previousRow containsObject:key.identifier]) {
					continue;	/* the same key as in the row above */
				}
				NP2KeyCap *cap = [[NP2KeyCap alloc] initWithKey:key block:(NSInteger)index];
				cap.onActivate = ^(NP2KeyCap *activated) {
					[weakSelf tapCap:activated];
				};
				[self addSubview:cap];
				[self->_caps addObject:cap];
			}
			previousRow = thisRow;
		}
	}];
	[_tabs removeAllSegments];
	[layout.blocks enumerateObjectsUsingBlock:^(NP2KeyBlock *block, NSUInteger index, BOOL *stop) {
		(void)stop;
		[self->_tabs insertSegmentWithTitle:block.title atIndex:index animated:NO];
	}];
	_page = 0;
	_tabs.selectedSegmentIndex = 0;
	[self refreshStates];
	[self setNeedsLayout];
}

// ---- geometry

- (CGFloat)unitsForBlocks:(NSArray<NP2KeyBlock *> *)blocks
{
	CGFloat units = 0;
	for (NP2KeyBlock *block in blocks) {
		units += block.width;
	}
	return units + kBlockGapUnits * (CGFloat)(blocks.count - 1);
}

/* All blocks when they fit, else the one chosen with the tabs. */
- (BOOL)pagedForWidth:(CGFloat)width
{
	NSArray<NP2KeyBlock *> *blocks = _layout.blocks;
	if (blocks.count <= 1) {
		return NO;
	}
	return (width - kPadding * 2) / [self unitsForBlocks:blocks] < kMinUnitWidth;
}

- (NSArray<NP2KeyBlock *> *)visibleBlocksForWidth:(CGFloat)width
{
	if ([self pagedForWidth:width]) {
		return @[ _layout.blocks[(NSUInteger)MIN(_page, (NSInteger)_layout.blocks.count - 1)] ];
	}
	return _layout.blocks;
}

/* Height of a row of height 1 for these blocks shown together: in
 * proportion to the key width, lower when it would not fit maxHeight. */
- (CGFloat)rowUnitHeightForBlocks:(NSArray<NP2KeyBlock *> *)blocks width:(CGFloat)width maxHeight:(CGFloat)maxHeight
{
	CGFloat unit = (width - kPadding * 2) / [self unitsForBlocks:blocks];
	CGFloat height = MIN(MAX(unit * 1.3, 36), kMaxRowHeight);
	CGFloat fixed = [self fixedHeightForBlocks:blocks width:width];
	CGFloat rows = [self rowsOfBlocks:blocks];
	if (fixed + height * rows > maxHeight) {
		height = MAX((maxHeight - fixed) / rows, kMinRowHeight);
	}
	return floor(height);
}

/* As above, filling the height instead (fillsHeight). */
- (CGFloat)fillRowUnitHeightForBlocks:(NSArray<NP2KeyBlock *> *)blocks width:(CGFloat)width height:(CGFloat)height
{
	CGFloat unit = (width - kPadding * 2) / [self unitsForBlocks:blocks];
	CGFloat rows = (height - [self fixedHeightForBlocks:blocks width:width]) / [self rowsOfBlocks:blocks];
	return floor(MAX(MIN(rows, unit * kMaxFillAspect), kMinRowHeight));
}

/* in row units */
- (CGFloat)rowsOfBlocks:(NSArray<NP2KeyBlock *> *)blocks
{
	CGFloat rows = 0;
	for (NP2KeyBlock *block in blocks) {
		rows = MAX(rows, block.height);
	}
	return rows;
}

/* padding, gaps between rows and the tabs */
- (CGFloat)fixedHeightForBlocks:(NSArray<NP2KeyBlock *> *)blocks width:(CGFloat)width
{
	NSUInteger rowCount = 0;
	for (NP2KeyBlock *block in blocks) {
		rowCount = MAX(rowCount, block.rows.count);
	}
	return kPadding * 2 + kKeyGap * (CGFloat)(rowCount - 1) + ([self hasTopRowForWidth:width] ? kTabsHeight + kKeyGap : 0);
}

- (CGFloat)heightOfBlocks:(NSArray<NP2KeyBlock *> *)blocks width:(CGFloat)width maxHeight:(CGFloat)maxHeight
{
	CGFloat rowHeight = [self rowUnitHeightForBlocks:blocks width:width maxHeight:maxHeight];
	return ceil([self fixedHeightForBlocks:blocks width:width] + rowHeight * [self rowsOfBlocks:blocks]);
}

/* Shown one at a time, the blocks get the height of the tallest, so that
 * switching tabs does not change it; a lower block leaves space below. */
- (CGFloat)heightForWidth:(CGFloat)width maxHeight:(CGFloat)maxHeight
{
	if (_layout == nil || width <= 0) {
		return 0;
	}
	if (![self pagedForWidth:width]) {
		return [self heightOfBlocks:_layout.blocks width:width maxHeight:maxHeight];
	}
	CGFloat height = 0;
	for (NP2KeyBlock *block in _layout.blocks) {
		height = MAX(height, [self heightOfBlocks:@[ block ] width:width maxHeight:maxHeight]);
	}
	return height;
}

- (void)layoutSubviews
{
	[super layoutSubviews];
	UIEdgeInsets safe = self.safeAreaInsets;
	CGRect area = CGRectMake(safe.left, 0, self.bounds.size.width - safe.left - safe.right,
		self.bounds.size.height - safe.bottom);
	CGFloat width = area.size.width;
	if (_layout == nil || width <= 0) {
		return;
	}
	BOOL paged = [self pagedForWidth:width];
	NSArray<NP2KeyBlock *> *blocks = [self visibleBlocksForWidth:width];
	CGFloat rowHeight = _fillsHeight
		? [self fillRowUnitHeightForBlocks:blocks width:width height:area.size.height]
		: [self rowUnitHeightForBlocks:blocks width:width maxHeight:area.size.height];
	CGFloat unit = (width - kPadding * 2) / [self unitsForBlocks:blocks];

	CGFloat top = area.origin.y + kPadding;
	BOOL switcher = _switchTitles.count > 0;
	_tabs.hidden = !paged;
	_switcher.hidden = !switcher;
	if (paged || switcher) {
		CGFloat full = width - kPadding * 2;
		/* the switcher on the left (as narrow as it reads well), the tabs in the rest */
		CGFloat switchWidth = switcher ? MIN(full * (paged ? 0.5 : 1.0), 92 * (CGFloat)_switchTitles.count) : 0;
		_switcher.frame = CGRectMake(area.origin.x + kPadding, top, switchWidth, kTabsHeight);
		CGFloat tabsX = switcher ? switchWidth + kKeyGap * 3 : 0;
		_tabs.frame = CGRectMake(area.origin.x + kPadding + tabsX, top, full - tabsX, kTabsHeight);
		top += kTabsHeight + kKeyGap;
	}
	if (_fillsHeight) {
		/* the tabs stay at the top; the keys in the middle of the rest */
		CGFloat used = [self fixedHeightForBlocks:blocks width:width] + rowHeight * [self rowsOfBlocks:blocks];
		top += floor(MAX(0, area.size.height - used) / 2);
	}

	_hitFrames = [NSMutableArray array];
	_hitCaps = [NSMutableArray array];
	NSMutableDictionary<NSValue *, NSMutableArray<NSValue *> *> *parts = [NSMutableDictionary dictionary];
	CGFloat x0 = area.origin.x + kPadding;
	for (NP2KeyBlock *block in blocks) {
		NSInteger blockIndex = (NSInteger)[_layout.blocks indexOfObject:block];
		NSArray<NP2KeyCap *> *caps = [self capsOfBlock:blockIndex];
		CGFloat y = top;
		NSMutableSet<NSString *> *previousRow = [NSMutableSet set];
		NSMutableDictionary<NSString *, NP2KeyCap *> *spanning = [NSMutableDictionary dictionary];
		NSUInteger capIndex = 0;
		for (NP2KeyRow *row in block.rows) {
			CGFloat h = rowHeight * row.height;
			CGFloat x = x0;
			NSMutableSet<NSString *> *thisRow = [NSMutableSet set];
			NSMutableDictionary<NSString *, NP2KeyCap *> *thisSpanning = [NSMutableDictionary dictionary];
			for (NP2Key *key in row.keys) {
				CGFloat w = unit * key.width;
				if (key.kind != NP2KeyKindSpacer) {
					NP2KeyCap *cap = [previousRow containsObject:key.identifier] ? spanning[key.identifier] : caps[capIndex++];
					[thisRow addObject:key.identifier];
					thisSpanning[key.identifier] = cap;
					CGRect rect = CGRectMake(x + kKeyGap / 2, y, w - kKeyGap, h);
					NSValue *capKey = [NSValue valueWithNonretainedObject:cap];
					if (parts[capKey] == nil) {
						parts[capKey] = [NSMutableArray array];
					}
					[parts[capKey] addObject:[NSValue valueWithCGRect:rect]];
					[_hitFrames addObject:[NSValue valueWithCGRect:CGRectMake(x, y - kKeyGap / 2, w, h + kKeyGap)]];
					[_hitCaps addObject:cap];
				}
				x += w;
			}
			previousRow = thisRow;
			spanning = thisSpanning;
			y += h + kKeyGap;
		}
		x0 += (block.width + kBlockGapUnits) * unit;
	}
	for (NP2KeyCap *cap in _caps) {
		NSArray<NSValue *> *capParts = parts[[NSValue valueWithNonretainedObject:cap]];
		cap.hidden = (capParts == nil);
		if (capParts) {
			[cap setParts:capParts];
		}
	}
}

- (NSArray<NP2KeyCap *> *)capsOfBlock:(NSInteger)block
{
	NSMutableArray<NP2KeyCap *> *caps = [NSMutableArray array];
	for (NP2KeyCap *cap in _caps) {
		if (cap.block == block) {
			[caps addObject:cap];
		}
	}
	return caps;
}

- (void)tabChanged
{
	[self releaseAll];
	_page = _tabs.selectedSegmentIndex;
	[self setNeedsLayout];
}

- (void)showBlock:(NSInteger)index
{
	if (index >= 0 && index < (NSInteger)_layout.blocks.count) {
		_tabs.selectedSegmentIndex = index;
		[self tabChanged];
	}
}

- (NP2KeyCap *)capAt:(CGPoint)point
{
	for (NSUInteger i = 0; i < _hitFrames.count; i++) {
		if (CGRectContainsPoint(_hitFrames[i].CGRectValue, point)) {
			return _hitCaps[i];
		}
	}
	return nil;
}

// ---- keys

/* Returns whether the key waits for the finger to lift. */
- (BOOL)pressCap:(NP2KeyCap *)cap
{
	NP2Key *key = cap.key;
	UINT8 code = (UINT8)(key.codes.firstObject.unsignedIntValue & 0x7f);
	switch (key.kind) {
		case NP2KeyKindModifier:
			if (_modifierCount[code] == 0 && keyinput_isactive(code)) {
				keyinput_togglemodifier(code);	/* latched: tapping again releases it */
				return NO;
			}
			if (_modifierCount[code]++ == 0) {
				_modifierUsed[code] = NO;
				keyinput_holdmodifier(code);
			}
			break;

		case NP2KeyKindLock:
			keyinput_togglemodifier(code);
			return NO;

		case NP2KeyKindKey:
		case NP2KeyKindChord:
			for (UINT i = 0; i < NELEMENTS(_modifierUsed); i++) {
				_modifierUsed[i] = YES;
			}
			for (NSNumber *number in key.codes) {
				UINT8 c = (UINT8)(number.unsignedIntValue & 0x7f);
				if (_keyCount[c]++ == 0) {
					keyinput_down(c);
				}
			}
			break;

		default:
			return NO;
	}
	cap.touches++;
	if (_hapticFeedback) {
		[_haptics impactOccurred];
	}
	[self refreshStates];
	[self showPreview:cap];
	return YES;
}

- (void)releaseCap:(NP2KeyCap *)cap
{
	NP2Key *key = cap.key;
	cap.touches = MAX(cap.touches - 1, 0);
	if (cap.touches == 0) {
		[[_previews objectForKey:cap] removeFromSuperview];
		[_previews removeObjectForKey:cap];
	}
	if (key.kind == NP2KeyKindModifier) {
		UINT8 code = (UINT8)(key.codes.firstObject.unsignedIntValue & 0x7f);
		if (_modifierCount[code] > 0 && --_modifierCount[code] == 0) {
			keyinput_releasemodifier(code, !_modifierUsed[code]);
		}
	}
	else {
		for (NSNumber *number in key.codes.reverseObjectEnumerator) {
			UINT8 c = (UINT8)(number.unsignedIntValue & 0x7f);
			if (_keyCount[c] > 0 && --_keyCount[c] == 0) {
				keyinput_up(c);
			}
		}
	}
	[self refreshStates];
}

// ---- key preview

/* A bubble a little wider than the key, above it, with the character it
 * types (shifted while SHIFT is held); not for function or editing keys. */
- (void)showPreview:(NP2KeyCap *)cap
{
	NP2Key *key = cap.key;
	if (!_keyPreview || key.kind != NP2KeyKindKey || key.style != NP2KeyStyleNormal
		|| [_previews objectForKey:cap] != nil) {
		return;
	}
	NSString *text = cap.shownLabel;
	if (keyinput_isactive(PC98KEY_SHIFT) && key.shiftedLabel && !cap.kana) {
		text = key.shiftedLabel;
	}
	if (text.length == 0 || text.length > 2) {
		return;
	}
	CGRect frame = cap.frame;
	CGFloat width = MAX(frame.size.width * 1.4, 44);
	CGFloat height = MIN(MAX(frame.size.height * 1.3, 48), 72);
	CGRect bubble = CGRectMake(CGRectGetMidX(frame) - width / 2, CGRectGetMinY(frame) - height - 4, width, height);
	/* inside the keyboard sideways; above it is fine (over the bar) */
	bubble.origin.x = MIN(MAX(bubble.origin.x, 2), self.bounds.size.width - width - 2);
	UILabel *label = [[UILabel alloc] initWithFrame:bubble];
	label.text = text;
	label.textAlignment = NSTextAlignmentCenter;
	label.textColor = UIColor.blackColor;
	label.font = [UIFont systemFontOfSize:height * 0.55 weight:UIFontWeightMedium];
	label.adjustsFontSizeToFitWidth = YES;
	label.backgroundColor = [UIColor colorWithWhite:0.92 alpha:1];
	label.layer.cornerRadius = 8;
	label.layer.masksToBounds = YES;
	label.userInteractionEnabled = NO;
	label.isAccessibilityElement = NO;
	[self addSubview:label];
	[_previews setObject:label forKey:cap];
}

- (void)tapCap:(NP2KeyCap *)cap
{
	if ([self pressCap:cap]) {
		[self releaseCap:cap];
	}
}

- (BOOL)tapKey:(NSString *)identifier
{
	for (NP2KeyCap *cap in _caps) {
		if (!cap.hidden && [cap.key.identifier isEqualToString:identifier]) {
			[self tapCap:cap];
			return YES;
		}
	}
	return NO;
}

- (BOOL)holdKey:(NSString *)identifier seconds:(NSTimeInterval)seconds
{
	for (NP2KeyCap *cap in _caps) {
		if (!cap.hidden && [cap.key.identifier isEqualToString:identifier]) {
			if ([self pressCap:cap]) {
				__weak NP2KeyboardView *weakSelf = self;
				dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
					[weakSelf releaseCap:cap];
				});
			}
			return YES;
		}
	}
	return NO;
}

- (void)releaseAll
{
	for (UITouch *touch in [[_touches keyEnumerator] allObjects]) {
		[self releaseCap:[_touches objectForKey:touch]];
	}
	[_touches removeAllObjects];
}

- (void)refreshStates
{
	BOOL kana = keyinput_isactive(PC98KEY_KANA);
	for (NP2KeyCap *cap in _caps) {
		NP2KeyKind kind = cap.key.kind;
		if ((kind == NP2KeyKindModifier || kind == NP2KeyKindLock)
			&& keyinput_isactive((UINT8)cap.key.codes.firstObject.unsignedIntValue)) {
			cap.state = CapStateActive;
		}
		else {
			cap.state = (cap.touches > 0) ? CapStatePressed : CapStateIdle;
		}
		cap.kana = kana;
	}
}

- (void)setHidden:(BOOL)hidden
{
	if (hidden) {
		[self releaseAll];
	}
	[super setHidden:hidden];
}

- (void)didMoveToWindow
{
	[super didMoveToWindow];
	if (self.window == nil) {
		[self releaseAll];
	}
}

// ---- touches

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	for (UITouch *touch in touches) {
		NP2KeyCap *cap = [self capAt:[touch locationInView:self]];
		if (cap && [self pressCap:cap]) {
			[_touches setObject:cap forKey:touch];
		}
	}
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	[self finishTouches:touches];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
	[self finishTouches:touches];
}

- (void)finishTouches:(NSSet<UITouch *> *)touches
{
	for (UITouch *touch in touches) {
		NP2KeyCap *cap = [_touches objectForKey:touch];
		if (cap) {
			[_touches removeObjectForKey:touch];
			[self releaseCap:cap];
		}
	}
}

@end
