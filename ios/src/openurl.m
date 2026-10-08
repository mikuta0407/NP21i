/**
 * @file	openurl.m
 * @brief	Files and np21:// links given to the app
 */

#include "compiler.h"
#include "openurl.h"
#include "keybar.h"
#include "profile.h"
#include "capture.h"
#include "clipboard.h"
#include "settingsview.h"

#import <UIKit/UIKit.h>
#include <fdd/diskdrv.h>

/* SDL's scene delegate (SDL3's SDL_uikitappdelegate.m, or SDL2's with patch 0002). */
@interface SDLUIKitSceneDelegate : NSObject <UIWindowSceneDelegate>
@end

@interface NP2SceneDelegate : SDLUIKitSceneDelegate
@end

static NSMutableArray<NSURL *> *s_pending;
static BOOL s_ready;

static void handle(NSURL *url);

void openurl_open(NSURL *url)
{
	if (!s_ready) {
		if (s_pending == nil) {
			s_pending = [NSMutableArray array];
		}
		[s_pending addObject:url];
		return;
	}
	handle(url);
}

void openurl_ready(void)
{
	s_ready = YES;
	NSArray<NSURL *> *pending = s_pending;
	s_pending = nil;
	for (NSURL *url in pending) {
		handle(url);
	}
}

@implementation NP2SceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions
{
	/* SDL also turns the URLs into drop events, which NP2 ignores */
	[super scene:scene willConnectToSession:session options:connectionOptions];
	for (UIOpenURLContext *context in connectionOptions.URLContexts) {
		openurl_open(context.URL);
	}
}

- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts
{
	(void)scene;
	for (UIOpenURLContext *context in URLContexts) {
		openurl_open(context.URL);
	}
}

@end

// ---- np21:// links

static void unusable(NSURL *url, NSString *why)
{
	keybar_showmessage(@"このリンクは使えません", [NSString stringWithFormat:@"%@\n%@", url.absoluteString, why]);
}

/* 1-based number in the path, or 0 */
static NSInteger number(NSArray<NSString *> *parts, NSUInteger index, NSInteger max)
{
	if (index >= parts.count) {
		return 0;
	}
	NSInteger n = parts[index].integerValue;
	return (n >= 1 && n <= max) ? n : 0;
}

static NSString *query_item(NSURL *url, NSString *name)
{
	for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems) {
		if ([item.name isEqualToString:name]) {
			return item.value;
		}
	}
	return nil;
}

static void confirm_type(NSString *text)
{
	NSString *shown = (text.length > 200) ? [[text substringToIndex:200] stringByAppendingString:@"…"] : text;
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"この文字を入力しますか？"
	                                                               message:shown preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
	[alert addAction:[UIAlertAction actionWithTitle:@"入力" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
		(void)a;
		clipboard_type(text);
	}]];
	[keybar_hostcontroller() presentViewController:alert animated:YES completion:nil];
}

static void handle_link(NSURL *url)
{
	/* np21://<command>/<arg>/...: the host is the command */
	NSString *command = url.host.lowercaseString ?: @"";
	NSMutableArray<NSString *> *args = [url.pathComponents mutableCopy] ?: [NSMutableArray array];
	if (args.count && [args.firstObject isEqualToString:@"/"]) {
		[args removeObjectAtIndex:0];
	}

	if ([command isEqualToString:@"env"]) {
		NSString *name = args.count ? [args componentsJoinedByString:@"/"] : query_item(url, @"name");
		for (NSString *identifier in profile_ids()) {
			if ([profile_name(identifier) isEqualToString:name]) {
				if (![identifier isEqualToString:profile_active()]) {
					settingsview_switchprofile(keybar_hostcontroller(), identifier);
				}
				return;
			}
		}
		unusable(url, [NSString stringWithFormat:@"「%@」という環境はありません。", name ?: @""]);
	}
	else if ([command isEqualToString:@"slot"]) {
		NSInteger slot = number(args, 1, PROFILE_SLOTS);
		NSString *what = args.count ? args[0] : @"";
		if (slot == 0) {
			unusable(url, @"スロットの番号は 1〜6 です。");
		}
		else if ([what isEqualToString:@"save"]) {
			if (!profile_saveslot(slot - 1)) {
				keybar_showmessage(@"保存できませんでした", nil);
			}
		}
		else if ([what isEqualToString:@"load"]) {
			if (profile_slotdate(slot - 1) == nil) {
				unusable(url, [NSString stringWithFormat:@"スロット %ld は空です。", (long)slot]);
			}
			else {
				keybar_confirmloadslot(slot - 1);
			}
		}
		else {
			unusable(url, @"slot/save/<番号> か slot/load/<番号> です。");
		}
	}
	else if ([command isEqualToString:@"fdd"]) {
		NSInteger drive = number(args, 0, 2);
		NSString *path = (args.count > 1) ? [[args subarrayWithRange:NSMakeRange(1, args.count - 1)] componentsJoinedByString:@"/"] : nil;
		if (drive == 0 || path.length == 0) {
			unusable(url, @"fdd/<1 か 2>/<データフォルダの中のパス> です。");
		}
		else if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {	/* cwd is the data directory */
			unusable(url, [NSString stringWithFormat:@"%@ がありません。", path]);
		}
		else {
			keybar_insertfdd((unsigned char)(drive - 1), path);
		}
	}
	else if ([command isEqualToString:@"eject"]) {
		NSInteger drive = number(args, 0, 2);
		if (drive == 0) {
			unusable(url, @"eject/<1 か 2> です。");
		}
		else {
			diskdrv_setfdd((REG8)(drive - 1), NULL, 0);
		}
	}
	else if ([command isEqualToString:@"type"]) {
		NSString *text = query_item(url, @"text");
		if (text.length == 0) {
			unusable(url, @"type?text=<文字> です。");
		}
		else {
			confirm_type(text);
		}
	}
	else if ([command isEqualToString:@"reset"]) {
		keybar_confirmreset();
	}
	else if ([command isEqualToString:@"screenshot"]) {
		capture_screenshot(keybar_hostcontroller());
	}
	else {
		unusable(url, @"使えるのは env、slot、fdd、eject、type、reset、screenshot です。");
	}
}

static void handle(NSURL *url)
{
	NSLog(@"openurl: %@", url);
	if (url.isFileURL) {
		keybar_openfile(url);
	}
	else if ([url.scheme.lowercaseString isEqualToString:@"np21"]) {
		handle_link(url);
	}
}
