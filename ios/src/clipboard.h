/**
 * @file	clipboard.h
 * @brief	Copying the PC-98 text screen, and typing text from the clipboard
 */

#pragma once

#import <UIKit/UIKit.h>

/* Copies the text screen (textscreen_text) to the clipboard. */
void clipboard_copyscreen(void);

/* Shows the text screen in a sheet, to copy all or a part of it. */
void clipboard_presentscreen(UIViewController *host);

/* Types the clipboard's text on the PC-98 keyboard, a key at a time. Only
 * what the keyboard can type gets through: ASCII, and kana (as half-width
 * katakana, with KANA locked meanwhile); other characters (kanji) are left
 * out. Asks first when the text is long or has such characters. */
void clipboard_paste(UIViewController *host);

/* Types `text` (no questions asked). Returns the number of characters left out. */
NSUInteger clipboard_type(NSString *text);
BOOL clipboard_istyping(void);
void clipboard_stoptyping(void);
