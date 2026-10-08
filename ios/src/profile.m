/**
 * @file	profile.m
 * @brief	Environments: sets of machine settings and disks to switch between
 *
 * profiles/<id>/profile.plist: name, created (date), fdd (paths of the
 * floppies in the drives, "" for none). profiles/<id>/np21kai.cfg and
 * np2.sav: the environment's files while another one is in use.
 *
 * Switching runs on the main thread between frames, as a reset from the
 * menu does. pccore_cfgupdate() takes the memory switches from the running
 * machine into np2cfg, so it is called before the config is saved, never
 * after the next one is loaded.
 */

#include "compiler.h"
#include "profile.h"
#include "lifecycle.h"
#include "midiport.h"
#include "settings.h"
#include "sdlcompat.h"
#include <pccore.h>
#include <nevent.h>
#include <ini.h>
#include <kbtrans.h>
#include <fdd/diskdrv.h>
#include <diskimage/fddfile.h>

NSNotificationName const NP2ProfilesChanged = @"NP2ProfilesChanged";

static NSString *const kActiveKey = @"profile_active";
static NSString *const kConfig = @"np21kai.cfg";
static NSString *const kState = @"np2.sav";
static NSString *const kInfo = @"profile.plist";
static NSString *const kDefaultID = @"default";

/* The config's hard disk entries (sdl/ini.c). */
static NSArray<NSString *> *hdd_keys(void)
{
	return @[ @"HDD1FILE", @"HDD2FILE", @"HDD3FILE", @"HDD4FILE", @"SCSIHDD0", @"SCSIHDD1", @"SCSIHDD2", @"SCSIHDD3" ];
}

static NSString *data_dir(void)
{
	return [NSFileManager defaultManager].currentDirectoryPath;
}

static NSString *profiles_dir(void)
{
	return [data_dir() stringByAppendingPathComponent:@"profiles"];
}

static NSString *dir_of(NSString *identifier)
{
	return [profiles_dir() stringByAppendingPathComponent:identifier];
}

static NSMutableDictionary *info_of(NSString *identifier)
{
	NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[dir_of(identifier) stringByAppendingPathComponent:kInfo]];
	return info ? [info mutableCopy] : [NSMutableDictionary dictionary];
}

static void write_info(NSString *identifier, NSDictionary *info)
{
	[info writeToFile:[dir_of(identifier) stringByAppendingPathComponent:kInfo] atomically:YES];
}

/* Copies from to to, replacing it; with no from, deletes to. */
static void replace_file(NSString *from, NSString *to)
{
	NSFileManager *fm = [NSFileManager defaultManager];
	[fm removeItemAtPath:to error:nil];
	if ([fm fileExistsAtPath:from]) {
		NSError *error = nil;
		if (![fm copyItemAtPath:from toPath:to error:&error]) {
			NSLog(@"profile: copying %@: %@", from.lastPathComponent, error.localizedDescription);
		}
	}
}

static void notify(void)
{
	[[NSNotificationCenter defaultCenter] postNotificationName:NP2ProfilesChanged object:nil];
}

void profile_initialize(void)
{
	NSFileManager *fm = [NSFileManager defaultManager];
	[fm createDirectoryAtPath:profiles_dir() withIntermediateDirectories:YES attributes:nil error:nil];
	NSString *active = [[NSUserDefaults standardUserDefaults] stringForKey:kActiveKey];
	if (active == nil || ![fm fileExistsAtPath:dir_of(active)]) {
		/* the files in use are the first environment's */
		active = kDefaultID;
		if (![fm fileExistsAtPath:dir_of(active)]) {
			[fm createDirectoryAtPath:dir_of(active) withIntermediateDirectories:YES attributes:nil error:nil];
			write_info(active, @{ @"name": @"標準", @"created": [NSDate date], @"fdd": @[] });
		}
		[[NSUserDefaults standardUserDefaults] setObject:active forKey:kActiveKey];
	}
}

NSArray<NSString *> *profile_ids(void)
{
	NSArray<NSString *> *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:profiles_dir() error:nil];
	NSMutableArray<NSString *> *ids = [NSMutableArray array];
	for (NSString *name in names) {
		if ([[NSFileManager defaultManager] fileExistsAtPath:[dir_of(name) stringByAppendingPathComponent:kInfo]]) {
			[ids addObject:name];
		}
	}
	[ids sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
		NSDate *da = info_of(a)[@"created"] ?: [NSDate distantPast];
		NSDate *db = info_of(b)[@"created"] ?: [NSDate distantPast];
		return [da compare:db];
	}];
	return ids;
}

NSString *profile_active(void)
{
	return [[NSUserDefaults standardUserDefaults] stringForKey:kActiveKey] ?: kDefaultID;
}

NSString *profile_name(NSString *identifier)
{
	return info_of(identifier)[@"name"] ?: identifier;
}

static NSString *slot_label(NSString *key)
{
	if ([key hasPrefix:@"SCSIHDD"]) {
		return [NSString stringWithFormat:@"SCSI #%@", [key substringFromIndex:7]];
	}
	return [NSString stringWithFormat:@"IDE #%@", [key substringWithRange:NSMakeRange(3, 1)]];
}

NSArray<NSString *> *profile_disks(NSString *identifier)
{
	NSString *dir = [identifier isEqualToString:profile_active()] ? data_dir() : dir_of(identifier);
	NSString *config = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:kConfig]
	                                             encoding:NSUTF8StringEncoding error:nil];
	NSMutableArray<NSString *> *disks = [NSMutableArray array];
	for (NSString *line in [config componentsSeparatedByString:@"\n"]) {
		NSRange eq = [line rangeOfString:@"="];
		if (eq.location == NSNotFound) {
			continue;
		}
		NSString *key = [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
		NSString *value = [[line substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
		if ([hdd_keys() containsObject:key] && value.length) {
			[disks addObject:[NSString stringWithFormat:@"%@: %@", slot_label(key), value.lastPathComponent]];
		}
	}
	return disks;
}

// ---- switching

static void save_config(void)
{
	pccore_cfgupdate();
	initsave();
}

/* The environment in use, into its directory. */
static void save_active(void)
{
	NSString *active = profile_active();
	save_config();
	lifecycle_savestate();
	NSMutableArray<NSString *> *fdd = [NSMutableArray array];
	for (REG8 drive = 0; drive < 2; drive++) {
		const OEMCHAR *name = fdd_diskname(drive);
		[fdd addObject:(name && name[0]) ? [NSString stringWithUTF8String:name] : @""];
	}
	NSMutableDictionary *info = info_of(active);
	info[@"fdd"] = fdd;
	[[NSFileManager defaultManager] createDirectoryAtPath:dir_of(active) withIntermediateDirectories:YES attributes:nil error:nil];
	write_info(active, info);
	replace_file([data_dir() stringByAppendingPathComponent:kConfig], [dir_of(active) stringByAppendingPathComponent:kConfig]);
	replace_file([data_dir() stringByAppendingPathComponent:kState], [dir_of(active) stringByAppendingPathComponent:kState]);
}

/* Another environment's files into the data directory, and the machine
 * started from them. */
static void load(NSString *identifier)
{
	NSString *config = [dir_of(identifier) stringByAppendingPathComponent:kConfig];
	if ([[NSFileManager defaultManager] fileExistsAtPath:config]) {
		replace_file(config, [data_dir() stringByAppendingPathComponent:kConfig]);
	}
	replace_file([dir_of(identifier) stringByAppendingPathComponent:kState], [data_dir() stringByAppendingPathComponent:kState]);

	diskdrv_setfdd(0, NULL, 0);
	diskdrv_setfdd(1, NULL, 0);
	initload();
	sdlkbd_reset();
	if (nevent_iswork(NEVENT_CDWAIT)) {
		nevent_forceexecute(NEVENT_CDWAIT);
	}
	pccore_reset();		/* opens the hard disks in np2cfg */
	if (!lifecycle_restorestate()) {
		NSArray<NSString *> *fdd = info_of(identifier)[@"fdd"];
		for (NSUInteger drive = 0; drive < MIN(fdd.count, 2u); drive++) {
			if (fdd[drive].length && [[NSFileManager defaultManager] fileExistsAtPath:fdd[drive]]) {
				diskdrv_setfdd((REG8)drive, fdd[drive].fileSystemRepresentation, 0);
			}
		}
	}
	midiport_refresh();
}

void profile_switch(NSString *identifier)
{
	if ([identifier isEqualToString:profile_active()] || ![[NSFileManager defaultManager] fileExistsAtPath:dir_of(identifier)]) {
		return;
	}
	NSLog(@"profile: %@ -> %@", profile_name(profile_active()), profile_name(identifier));
	save_active();
	[[NSUserDefaults standardUserDefaults] setObject:identifier forKey:kActiveKey];
	load(identifier);
	notify();
}

// ---- export and import

static NSString *map_hdds(NSString *config, NSString *(^map)(NSString *value));

static NSError *failure(NSString *message)
{
	return [NSError errorWithDomain:@"NP21Profile" code:1 userInfo:@{ NSLocalizedDescriptionKey: message }];
}

/* dir/name, or dir/name 2.ext ... if that exists. */
static NSString *unique_in(NSString *dir, NSString *name)
{
	NSString *base = name.stringByDeletingPathExtension;
	NSString *ext = name.pathExtension;
	for (int n = 1; ; n++) {
		NSString *file = (n == 1) ? base : [NSString stringWithFormat:@"%@ %d", base, n];
		NSString *path = [dir stringByAppendingPathComponent:ext.length ? [file stringByAppendingPathExtension:ext] : file];
		if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
			return path;
		}
	}
}

NSURL *profile_export(NSString *identifier, NSError **error)
{
	NSFileManager *fm = [NSFileManager defaultManager];
	BOOL active = [identifier isEqualToString:profile_active()];
	if (active) {
		save_active();		/* its files now, and a copy in its directory */
	}
	NSString *dir = dir_of(identifier);
	NSString *config = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:kConfig] encoding:NSUTF8StringEncoding error:error];
	if (config == nil) {
		return nil;
	}
	NSString *name = profile_name(identifier);
	NSString *safe = [[name componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/:\\"]] componentsJoinedByString:@"_"];
	NSString *package = [NSTemporaryDirectory() stringByAppendingPathComponent:[safe stringByAppendingPathExtension:@"np21env"]];
	[fm removeItemAtPath:package error:nil];
	for (NSString *sub in @[ @"hdd", @"fdd" ]) {
		if (![fm createDirectoryAtPath:[package stringByAppendingPathComponent:sub] withIntermediateDirectories:YES attributes:nil error:error]) {
			return nil;
		}
	}
	__block NSError *copyError = nil;
	NSMutableDictionary<NSString *, NSString *> *copied = [NSMutableDictionary dictionary];
	NSString *(^take)(NSString *, NSString *) = ^NSString *(NSString *value, NSString *sub) {
		if (value.length == 0 || ![fm fileExistsAtPath:value] || copyError) {
			return nil;
		}
		if (copied[value] == nil) {
			NSString *to = unique_in([package stringByAppendingPathComponent:sub], value.lastPathComponent);
			NSError *e = nil;
			if (![fm copyItemAtPath:value toPath:to error:&e]) {
				copyError = e;
				return nil;
			}
			copied[value] = [sub stringByAppendingPathComponent:to.lastPathComponent];
		}
		return copied[value];
	};
	config = map_hdds(config, ^NSString *(NSString *value) { return take(value, @"hdd"); });
	NSMutableArray<NSString *> *fdd = [NSMutableArray array];
	for (NSString *path in info_of(identifier)[@"fdd"] ?: @[]) {
		[fdd addObject:take(path, @"fdd") ?: @""];
	}
	if (copyError) {
		[fm removeItemAtPath:package error:nil];
		if (error) {
			*error = copyError;
		}
		return nil;
	}
	[config writeToFile:[package stringByAppendingPathComponent:kConfig] atomically:YES encoding:NSUTF8StringEncoding error:nil];
	NSString *state = [dir stringByAppendingPathComponent:kState];
	if ([fm fileExistsAtPath:state]) {
		[fm copyItemAtPath:state toPath:[package stringByAppendingPathComponent:kState] error:nil];
	}
	NSMutableDictionary *info = [info_of(identifier) mutableCopy];
	info[@"fdd"] = fdd;
	/* where each image was: the saved state opens the disks by those paths */
	NSMutableDictionary<NSString *, NSString *> *images = [NSMutableDictionary dictionary];
	for (NSString *original in copied) {
		images[copied[original]] = original;
	}
	info[@"images"] = images;
	[info writeToFile:[package stringByAppendingPathComponent:kInfo] atomically:YES];
	NSLog(@"profile: exported %@ (%lu images)", name, (unsigned long)copied.count);
	return [NSURL fileURLWithPath:package];
}

NSString *profile_import(NSURL *folder, NSError **error)
{
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *package = folder.path;
	NSString *config = [NSString stringWithContentsOfFile:[package stringByAppendingPathComponent:kConfig] encoding:NSUTF8StringEncoding error:nil];
	if (config == nil) {
		if (error) {
			*error = failure(@"環境のフォルダ（.np21env）ではありません。np21kai.cfg がありません。");
		}
		return nil;
	}
	NSMutableDictionary *info = [[NSDictionary dictionaryWithContentsOfFile:[package stringByAppendingPathComponent:kInfo]] mutableCopy]
		?: [NSMutableDictionary dictionary];
	__block NSError *copyError = nil;
	__block BOOL samePaths = (info[@"images"] != nil);
	NSDictionary<NSString *, NSString *> *originals = info[@"images"];
	NSMutableArray<NSString *> *added = [NSMutableArray array];
	NSString *(^bring)(NSString *) = ^NSString *(NSString *value) {
		NSString *from = [package stringByAppendingPathComponent:value];
		if (value.length == 0 || [value hasPrefix:@"/"] || ![fm fileExistsAtPath:from] || copyError) {
			return nil;
		}
		NSString *sub = value.pathComponents.firstObject;
		[fm createDirectoryAtPath:sub withIntermediateDirectories:YES attributes:nil error:nil];
		NSString *to = unique_in(sub, value.lastPathComponent);
		NSError *e = nil;
		if (![fm copyItemAtPath:from toPath:to error:&e]) {
			copyError = e;
			return nil;
		}
		[added addObject:to];
		if (![originals[value] isEqualToString:to]) {
			samePaths = NO;
		}
		return to;
	};
	config = map_hdds(config, ^NSString *(NSString *value) { return bring(value); });
	NSMutableArray<NSString *> *fdd = [NSMutableArray array];
	for (NSString *path in info[@"fdd"] ?: @[]) {
		[fdd addObject:bring(path) ?: @""];
	}
	NSString *identifier = [NSUUID UUID].UUIDString;
	if (copyError || ![fm createDirectoryAtPath:dir_of(identifier) withIntermediateDirectories:YES attributes:nil error:error]) {
		for (NSString *path in added) {
			[fm removeItemAtPath:path error:nil];
		}
		if (error && copyError) {
			*error = copyError;
		}
		return nil;
	}
	[config writeToFile:[dir_of(identifier) stringByAppendingPathComponent:kConfig] atomically:YES encoding:NSUTF8StringEncoding error:nil];
	/* The saved state opens the disks where they were: only with the same
	 * paths here, or it would open another environment's disk. */
	NSString *state = [package stringByAppendingPathComponent:kState];
	if (samePaths && [fm fileExistsAtPath:state]) {
		[fm copyItemAtPath:state toPath:[dir_of(identifier) stringByAppendingPathComponent:kState] error:nil];
	}
	else if ([fm fileExistsAtPath:state]) {
		NSLog(@"profile: import without its saved state (the disks are elsewhere)");
	}
	[info removeObjectForKey:@"images"];
	NSString *name = info[@"name"] ?: folder.lastPathComponent.stringByDeletingPathExtension;
	NSMutableSet<NSString *> *names = [NSMutableSet set];
	for (NSString *other in profile_ids()) {
		[names addObject:profile_name(other)];
	}
	NSString *unique = name;
	for (int n = 2; [names containsObject:unique]; n++) {
		unique = [NSString stringWithFormat:@"%@ %d", name, n];
	}
	info[@"name"] = unique;
	info[@"created"] = [NSDate date];
	info[@"fdd"] = fdd;
	write_info(identifier, info);
	NSLog(@"profile: imported %@ (%lu images)", unique, (unsigned long)added.count);
	notify();
	return identifier;
}

// ---- making and removing

/* The config with each hard disk entry's value changed by map (nil: kept). */
static NSString *map_hdds(NSString *config, NSString *(^map)(NSString *value))
{
	NSMutableArray<NSString *> *lines = [NSMutableArray array];
	for (NSString *line in [config componentsSeparatedByString:@"\n"]) {
		NSRange eq = [line rangeOfString:@"="];
		NSString *key = (eq.location != NSNotFound)
			? [[line substringToIndex:eq.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] : nil;
		if (key && [hdd_keys() containsObject:key]) {
			NSString *value = [[line substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
			NSString *mapped = map(value);
			if (mapped) {
				[lines addObject:[NSString stringWithFormat:@"%@ = %@", key, mapped]];
				continue;
			}
		}
		[lines addObject:line];
	}
	return [lines componentsJoinedByString:@"\n"];
}

/* hdd/<name>-<image name>, or with " 2" ... if that exists (relative). */
static NSString *copy_name(NSString *image, NSString *name)
{
	NSString *safe = [[name componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/:\\"]]
		componentsJoinedByString:@"_"];
	NSString *base = [NSString stringWithFormat:@"%@-%@", image.lastPathComponent.stringByDeletingPathExtension, safe];
	NSString *ext = image.pathExtension;
	for (int n = 1; ; n++) {
		NSString *file = (n == 1) ? base : [NSString stringWithFormat:@"%@ %d", base, n];
		NSString *path = [@"hdd" stringByAppendingPathComponent:[file stringByAppendingPathExtension:ext]];
		if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
			return path;
		}
	}
}

NSString *profile_create(NSString *name, NP2ProfileDisks disks, NSError **error)
{
	NSFileManager *fm = [NSFileManager defaultManager];
	save_config();
	NSString *config = [NSString stringWithContentsOfFile:[data_dir() stringByAppendingPathComponent:kConfig]
	                                             encoding:NSUTF8StringEncoding error:error];
	if (config == nil) {
		return nil;
	}
	if (disks == NP2ProfileDisksNone) {
		config = map_hdds(config, ^NSString *(NSString *value) { return @""; });
	}
	else if (disks == NP2ProfileDisksCopy) {
		[fm createDirectoryAtPath:@"hdd" withIntermediateDirectories:YES attributes:nil error:nil];
		__block NSError *failure = nil;
		NSMutableDictionary<NSString *, NSString *> *copies = [NSMutableDictionary dictionary];
		config = map_hdds(config, ^NSString *(NSString *value) {
			if (value.length == 0 || ![fm fileExistsAtPath:value] || failure) {
				return nil;
			}
			if (copies[value] == nil) {
				NSString *copy = copy_name(value, name);
				NSError *e = nil;
				if (![fm copyItemAtPath:value toPath:copy error:&e]) {		/* a clone on APFS */
					failure = e;
					return nil;
				}
				NSLog(@"profile: %@ copied to %@", value, copy);
				copies[value] = copy;
			}
			return copies[value];
		});
		if (failure) {
			for (NSString *copy in copies.allValues) {
				[fm removeItemAtPath:copy error:nil];
			}
			if (error) {
				*error = failure;
			}
			return nil;
		}
	}

	NSString *identifier = [NSUUID UUID].UUIDString;
	if (![fm createDirectoryAtPath:dir_of(identifier) withIntermediateDirectories:YES attributes:nil error:error]
		|| ![config writeToFile:[dir_of(identifier) stringByAppendingPathComponent:kConfig] atomically:YES
		               encoding:NSUTF8StringEncoding error:error]) {
		return nil;
	}
	write_info(identifier, @{ @"name": name, @"created": [NSDate date], @"fdd": @[] });
	notify();
	return identifier;
}

void profile_rename(NSString *identifier, NSString *name)
{
	NSMutableDictionary *info = info_of(identifier);
	info[@"name"] = name;
	write_info(identifier, info);
	notify();
}

void profile_delete(NSString *identifier)
{
	if ([identifier isEqualToString:profile_active()]) {
		return;
	}
	[[NSFileManager defaultManager] removeItemAtPath:dir_of(identifier) error:nil];
	notify();
}
