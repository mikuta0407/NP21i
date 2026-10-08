/**
 * @file	kbdlayout.h
 * @brief	Layouts for the on-screen keyboard (kbdview.h)
 *
 * A layout is data: blocks of rows of keys, each key a PC-98 key position
 * (or several, for a chord) with a width in key units. The view draws and
 * drives any layout, so another keyboard (e.g. one for Recomposer's
 * commands) is a new layout function added to +allLayouts, nothing more.
 */

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, NP2KeyKind) {
	NP2KeyKindKey,		/* down while touched */
	NP2KeyKindModifier,	/* SHIFT / CTRL / GRPH: held while touched; tapped alone, applies to the next key */
	NP2KeyKindLock,		/* CAPS / KANA: each tap toggles */
	NP2KeyKindChord,	/* all codes down while touched (in order), e.g. GRPH+X */
	NP2KeyKindSpacer	/* empty space */
};

typedef NS_ENUM(NSInteger, NP2KeyStyle) {
	NP2KeyStyleNormal,	/* character keys */
	NP2KeyStyleDark,	/* function, editing and modifier keys */
	NP2KeyStyleAccent	/* stands out (e.g. a layout's main commands) */
};

/* Built with the chained setters below, once, when a layout is made. */
@interface NP2Key : NSObject

/* Unique within a row. The same identifier in adjacent rows of a block is
 * one key drawn across them (the PC-98 RETURN, an inverted L). */
@property (nonatomic, readonly, copy) NSString *identifier;
@property (nonatomic, readonly) NP2KeyKind kind;
/* PC-98 key codes (keyinput.h); one except for chords */
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *codes;
@property (nonatomic, readonly, copy) NSString *label;
/* small, above the label: what SHIFT types; nil when it is the same key */
@property (nonatomic, readonly, copy, nullable) NSString *shiftedLabel;
/* shown instead of the label while KANA is locked */
@property (nonatomic, readonly, copy, nullable) NSString *kanaLabel;
/* for VoiceOver, when the label is not a word ("←", "f·1") */
@property (nonatomic, readonly, copy, nullable) NSString *spokenName;
@property (nonatomic, readonly) double width;
@property (nonatomic, readonly) NP2KeyStyle style;

+ (NP2Key *)key:(NSString *)identifier label:(NSString *)label code:(unsigned char)code;
+ (NP2Key *)modifier:(NSString *)identifier label:(NSString *)label code:(unsigned char)code;
+ (NP2Key *)lock:(NSString *)identifier label:(NSString *)label code:(unsigned char)code;
+ (NP2Key *)chord:(NSString *)identifier label:(NSString *)label codes:(NSArray<NSNumber *> *)codes;
+ (NP2Key *)spacer:(double)width;

- (NP2Key *)width:(double)width;
- (NP2Key *)shifted:(nullable NSString *)label;
- (NP2Key *)kana:(nullable NSString *)label;
- (NP2Key *)spoken:(nullable NSString *)name;
- (NP2Key *)style:(NP2KeyStyle)style;

@end

@interface NP2KeyRow : NSObject
@property (nonatomic, readonly, copy) NSArray<NP2Key *> *keys;
/* relative to an ordinary row (the function key row is lower) */
@property (nonatomic, readonly) double height;
@property (nonatomic, readonly) double totalWidth;
+ (NP2KeyRow *)row:(NSArray<NP2Key *> *)keys;
+ (NP2KeyRow *)row:(NSArray<NP2Key *> *)keys height:(double)height;
@end

/* A group of keys shown together: the view puts all blocks of a layout side
 * by side when they fit, else one at a time with tabs. All blocks of a
 * layout should have the same row heights, so that their rows line up. */
@interface NP2KeyBlock : NSObject
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, copy) NSArray<NP2KeyRow *> *rows;
@property (nonatomic, readonly) double width;		/* the widest row, in key units */
@property (nonatomic, readonly) double height;		/* sum of the row heights */
+ (NP2KeyBlock *)block:(NSString *)title rows:(NSArray<NP2KeyRow *> *)rows;
@end

@interface NP2KeyboardLayout : NSObject
@property (nonatomic, readonly, copy) NSString *identifier;	/* stored in the settings */
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly, copy) NSArray<NP2KeyBlock *> *blocks;
+ (NP2KeyboardLayout *)layout:(NSString *)identifier title:(NSString *)title blocks:(NSArray<NP2KeyBlock *> *)blocks;

/* Every layout the app offers, in menu order. */
+ (NSArray<NP2KeyboardLayout *> *)allLayouts;
+ (nullable NP2KeyboardLayout *)layoutWithIdentifier:(NSString *)identifier;

/* The PC-9801 keyboard: the main keys, and the editing keys with the
 * numeric keypad. */
+ (NP2KeyboardLayout *)pc98Layout;
/* For games: arrows, Z / X / SPACE / RETURN, SHIFT / CTRL, ESC, f·1-5,
 * 1-5, Y / N. */
+ (NP2KeyboardLayout *)gameLayout;
@end

NS_ASSUME_NONNULL_END
