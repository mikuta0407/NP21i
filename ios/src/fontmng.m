/**
 * @file	fontmng.m
 * @brief	The font manager (sdl/fontmng.c) drawn with Core Text
 *
 * Without FONT.ROM, NP2 makes the PC-98 font (font.tmp in the data
 * directory) by asking this for each character (font/fontmake.c), so kanji
 * need a font with them: a TrueType font put in the data directory as
 * default.ttf, the cfg's fontface, or Hiragino. The NP2 menu (12 pixels)
 * keeps the built-in ANK bitmaps of sdl/fontmng.c for ASCII.
 */

#import <CoreText/CoreText.h>
#import <Foundation/Foundation.h>

#include "compiler.h"
#include <dosio.h>
#include <fontmng.h>
#include <pccore.h>

#include "ank12.res"

static NSString *const kDefaultFont = @"HiraginoSans-W3";
/* font.tmp was made from this; another font (or the earlier font manager,
 * which had no kanji) makes it again */
static NSString *const kFontTmpKey = @"font_tmp_source";
static const OEMCHAR kFontTmpName[] = OEMTEXT("font.tmp");
/* a pixel at least this covered is set: thin strokes between two pixels
 * cover each by half, and should not vanish */
static const UINT8 kThreshold = 0x50;

static char s_fontfile[MAX_PATH];	/* default.ttf, when there is one */

struct TagFontManager {
	int size;
	UINT type;
	CTFontRef font;			/* NULL: the ANK bitmaps only */
	CGFloat descent;
	CGContextRef context;	/* size x size, 8 bits gray */
	/* followed by one character's _FNTDAT and pixels */
};
typedef struct TagFontManager *FNTMNG;

static CTFontRef create_font(CGFloat size, const char *face)
{
	CTFontRef font = NULL;
	if (s_fontfile[0]) {
		NSURL *url = [NSURL fileURLWithPath:@(s_fontfile)];
		NSArray *descriptors = CFBridgingRelease(CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)url));
		if (descriptors.count > 0) {
			font = CTFontCreateWithFontDescriptor((__bridge CTFontDescriptorRef)descriptors[0], size, NULL);
		}
	}
	if (font == NULL && face && face[0]) {
		/* Core Text falls back to some font for an unknown name: only a real match */
		NSString *name = @(face);
		CTFontRef named = CTFontCreateWithName((__bridge CFStringRef)name, size, NULL);
		NSString *got = CFBridgingRelease(CTFontCopyPostScriptName(named));
		NSString *family = CFBridgingRelease(CTFontCopyFamilyName(named));
		if ([got isEqualToString:name] || [family isEqualToString:name]) {
			font = named;
		}
		else {
			CFRelease(named);
		}
	}
	if (font == NULL) {
		font = CTFontCreateWithName((__bridge CFStringRef)kDefaultFont, size, NULL);
	}
	return font;
}

/* What font.tmp would be made from now. */
static NSString *font_source(void)
{
	return [NSString stringWithFormat:@"coretext 3 %s|%s", s_fontfile, np2cfg.fontface];
}

BRESULT fontmng_init(void)
{
	/* np2.c calls this in the data directory, before font_load() */
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	NSString *source = font_source();
	if (![[defaults stringForKey:kFontTmpKey] isEqualToString:source]) {
		file_delete(file_getcd(kFontTmpName));
		[defaults setObject:source forKey:kFontTmpKey];
	}
	return SUCCESS;
}

void fontmng_setdeffontname(const char *name)
{
	milstr_ncpy(s_fontfile, name, NELEMENTS(s_fontfile));
}

void *fontmng_create(int size, UINT type, const char *fontface)
{
	if (size < 0) {
		size = -size;
	}
	size = MIN(MAX(size, 6), 128);

	FNTMNG ret = (FNTMNG)_MALLOC(sizeof(*ret) + sizeof(_FNTDAT) + size * size, "font mng");
	if (ret == NULL) {
		return NULL;
	}
	memset(ret, 0, sizeof(*ret));
	ret->size = size;
	ret->type = type;

	/* as large as fits the height: ascent + descent = size */
	CTFontRef font = create_font(size, fontface);
	CGFloat height = CTFontGetAscent(font) + CTFontGetDescent(font);
	CGFloat pt = size * size / MAX(height, 1);
	CFRelease(font);
	font = create_font(pt, fontface);
	if (type & FDAT_BOLD) {
		CTFontRef bold = CTFontCreateCopyWithSymbolicTraits(font, 0, NULL, kCTFontBoldTrait, kCTFontBoldTrait);
		if (bold) {
			CFRelease(font);
			font = bold;
		}
	}
	ret->font = font;
	ret->descent = CTFontGetDescent(font);

	CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
	ret->context = CGBitmapContextCreate(NULL, size, size, 8, size, gray, (CGBitmapInfo)kCGImageAlphaNone);
	CGColorSpaceRelease(gray);
	if (ret->context == NULL) {
		CFRelease(ret->font);
		_MFREE(ret);
		return NULL;
	}
	CGContextSetShouldSmoothFonts(ret->context, false);
	CGContextSetGrayFillColor(ret->context, 1, 1);
	return ret;
}

void fontmng_destroy(void *hdl)
{
	FNTMNG _this = (FNTMNG)hdl;
	if (_this) {
		CGContextRelease(_this->context);
		if (_this->font) {
			CFRelease(_this->font);
		}
		_MFREE(_this);
	}
}

/* ---- the built-in ANK bitmaps (as sdl/fontmng.c) */

static BOOL ank_usable(FNTMNG _this, UINT16 c)
{
	return (c >= 0x20) && (c < 0x80) && (_this->size <= ANKFONTSIZE);
}

static void ank_header(FNTMNG _this, FNTDAT fdat, int width)
{
	if (_this->type & FDAT_PROPORTIONAL) {
		fdat->width = width;
		fdat->pitch = width + 1;
	}
	else {
		fdat->width = MAX(width, _this->size >> 1);
		fdat->pitch = (_this->size >> 1) + 1;
	}
	fdat->height = _this->size;
}

static void ank_length(FNTMNG _this, FNTDAT fdat, UINT16 c)
{
	ank_header(_this, fdat, ankfont[(c - 0x20) * ANKFONTSIZE]);
}

static void ank_glyph(FNTMNG _this, FNTDAT fdat, UINT16 c)
{
	const UINT8 *src = ankfont + ((c - 0x20) * ANKFONTSIZE);
	int width = *src++;
	ank_header(_this, fdat, width);
	UINT8 *dst = (UINT8 *)(fdat + 1);
	memset(dst, 0, fdat->width * fdat->height);
	dst += MAX(0, (fdat->height - ANKFONTSIZE) / 2) * fdat->width;
	dst += (fdat->width - width) / 2;
	for (int y = 0; y < ANKFONTSIZE - 1 && y + 1 < fdat->height; y++) {
		dst += fdat->width;
		for (int x = 0; x < width; x++) {
			dst[x] = (src[0] & (0x80 >> x)) ? FDAT_DEPTH : 0;
		}
		src++;
	}
}

/* ---- Core Text */

/* PC-98 characters are half (ASCII, half-width kana) or full width. */
static BOOL is_halfwidth(UINT16 c)
{
	return (c < 0x100) || (c >= 0xff61 && c <= 0xff9f);
}

static CTLineRef create_line(FNTMNG _this, UINT16 c)
{
	/* where ASCII has \ and ~, the PC-98 has a yen sign and an overline */
	unichar u = (c == '\\') ? 0x00a5 : (c == '~') ? 0x203e : c;
	NSString *string = [NSString stringWithCharacters:&u length:1];
	NSDictionary *attributes = @{(__bridge NSString *)kCTFontAttributeName: (__bridge id)_this->font,
		(__bridge NSString *)kCTForegroundColorFromContextAttributeName: @YES};
	NSAttributedString *text = [[NSAttributedString alloc] initWithString:string attributes:attributes];
	return CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)text);
}

static void ct_header(FNTMNG _this, FNTDAT fdat, UINT16 c, CGFloat advance)
{
	int width;
	if (_this->type & FDAT_PROPORTIONAL) {
		width = MIN(MAX((int)ceil(advance), 1), _this->size);
	}
	else {
		width = is_halfwidth(c) ? (_this->size >> 1) : _this->size;
	}
	fdat->width = width;
	fdat->pitch = width;
	fdat->height = _this->size;
}

static void ct_length(FNTMNG _this, FNTDAT fdat, UINT16 c)
{
	CTLineRef line = create_line(_this, c);
	ct_header(_this, fdat, c, CTLineGetTypographicBounds(line, NULL, NULL, NULL));
	CFRelease(line);
}

static void ct_glyph(FNTMNG _this, FNTDAT fdat, UINT16 c)
{
	CTLineRef line = create_line(_this, c);
	CGFloat advance = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
	ct_header(_this, fdat, c, advance);

	/* white on black, the glyph in the middle of its cell, on the baseline */
	CGContextRef context = _this->context;
	int size = _this->size;
	CGContextSetGrayFillColor(context, 0, 1);
	CGContextFillRect(context, CGRectMake(0, 0, size, size));
	CGContextSetGrayFillColor(context, 1, 1);
	/* wider than its cell (Latin letters are, in a Japanese font): narrowed */
	CGFloat scale = (advance > fdat->width) ? fdat->width / advance : 1;
	CGContextSetTextMatrix(context, CGAffineTransformMakeScale(scale, 1));
	CGContextSetTextPosition(context, round((fdat->width - advance * scale) / 2), round(_this->descent));
	CTLineDraw(line, context);
	CFRelease(line);

	/* the bitmap's first row is the top */
	const UINT8 *src = CGBitmapContextGetData(context);
	size_t stride = CGBitmapContextGetBytesPerRow(context);
	UINT8 *dst = (UINT8 *)(fdat + 1);
	BOOL alias = (_this->type & FDAT_ALIAS) != 0;
	for (int y = 0; y < fdat->height; y++) {
		for (int x = 0; x < fdat->width; x++) {
			UINT8 v = src[y * stride + x];
			*dst++ = alias ? (UINT8)(v * FDAT_DEPTH / 255) : ((v >= kThreshold) ? FDAT_DEPTH : 0);
		}
	}
}

static void get_length(FNTMNG _this, FNTDAT fdat, UINT16 c)
{
	if (ank_usable(_this, c)) {
		ank_length(_this, fdat, c);
	}
	else {
		ct_length(_this, fdat, c);
	}
}

/* One character of UTF-8 (the OEM text), 0 at the end. */
static UINT16 get_char(const char **lppString)
{
	const char *s = *lppString;
	UINT16 c = 0;
	if (s == NULL) {
		return 0;
	}
	if ((s[0] & 0x80) == 0) {
		c = s[0] & 0x7f;
		s += (c != 0);
	}
	else if (((s[0] & 0xe0) == 0xc0) && ((s[1] & 0xc0) == 0x80)) {
		c = ((s[0] & 0x1f) << 6) | (s[1] & 0x3f);
		s += 2;
	}
	else if (((s[0] & 0xf0) == 0xe0) && ((s[1] & 0xc0) == 0x80) && ((s[2] & 0xc0) == 0x80)) {
		c = ((s[0] & 0x0f) << 12) | ((s[1] & 0x3f) << 6) | (s[2] & 0x3f);
		s += 3;
	}
	*lppString = s;
	return c;
}

BRESULT fontmng_getsize(void *hdl, const char *lpString, POINT_T *pt)
{
	FNTMNG _this = (FNTMNG)hdl;
	if ((_this == NULL) || (lpString == NULL)) {
		return FAILURE;
	}
	int width = 0;
	UINT16 c;
	_FNTDAT fdat;
	while ((c = get_char(&lpString)) != 0) {
		get_length(_this, &fdat, c);
		width += fdat.pitch;
	}
	if (pt) {
		pt->x = width;
		pt->y = _this->size;
	}
	return SUCCESS;
}

BRESULT fontmng_getdrawsize(void *hdl, const char *lpString, POINT_T *pt)
{
	FNTMNG _this = (FNTMNG)hdl;
	if (_this == NULL) {
		return FAILURE;
	}
	int width = 0;
	int x = 0;
	UINT16 c;
	_FNTDAT fdat;
	while ((c = get_char(&lpString)) != 0) {
		get_length(_this, &fdat, c);
		width = x + MAX(fdat.width, fdat.pitch);
		x += fdat.pitch;
	}
	if (pt) {
		pt->x = width;
		pt->y = _this->size;
	}
	return SUCCESS;
}

FNTDAT fontmng_get(void *hdl, const char *lpString)
{
	FNTMNG _this = (FNTMNG)hdl;
	if (_this == NULL) {
		return NULL;
	}
	UINT16 c = get_char(&lpString);
	if (c == 0) {
		return NULL;
	}
	FNTDAT fdat = (FNTDAT)(_this + 1);
	if (ank_usable(_this, c)) {
		ank_glyph(_this, fdat, c);
	}
	else {
		ct_glyph(_this, fdat, c);
	}
	return fdat;
}
