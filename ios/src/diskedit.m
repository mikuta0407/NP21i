/**
 * @file	diskedit.m
 * @brief	Screens for the files in disk images, and setting up the host drive
 *
 * Files are read and written with diskfs.c, straight in the image file.
 * An image the PC-98 is using needs care, as the guest caches its FAT and
 * directories:
 * - a floppy is taken out while it is edited and put back after, which DOS
 *   sees as a disk change;
 * - a hard disk stays in, NP2's file handle is closed (sxsi_allflash, NP2
 *   reopens it on the next access) before each operation, and the PC-98 is
 *   reset when the screens close if anything was changed.
 * Each operation opens the image afresh, so it never works from a FAT read
 * before the guest last wrote. The emulator is paused while these screens
 * are shown (NP2PausingNavigationController), so the guest does not write
 * in between.
 *
 * DOS names are Shift_JIS (code page 932) in 8.3 form; names from iOS are
 * converted, shortened with "~1" when they do not fit.
 */

#include "compiler.h"
#include "diskedit.h"
#include "diskfs.h"
#include "keybar.h"
#include "settings.h"
#include "lifecycle.h"

#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <pccore.h>
#include <fdd/diskdrv.h>
#include <fdd/sxsi.h>
#include <diskimage/fddfile.h>
#include <generic/hostdrv.h>

static NSString *const kHostDriveDir = @"hostdrv/";

// ---- names

static NSStringEncoding sjis_encoding(void)
{
	return CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingDOSJapanese);
}

static NSString *from_sjis(const char *s)
{
	NSString *string = [[NSString alloc] initWithBytes:s length:strlen(s) encoding:sjis_encoding()];
	return string ?: [[NSString alloc] initWithBytes:s length:strlen(s) encoding:NSISOLatin1StringEncoding];
}

/* NUL-terminated; characters without a Shift_JIS form become '?' (and then
 * '_' in a short name). */
static NSData *to_sjis(NSString *s)
{
	NSMutableData *data = [[s dataUsingEncoding:sjis_encoding() allowLossyConversion:YES] mutableCopy] ?: [NSMutableData data];
	[data appendBytes:"" length:1];
	return data;
}

static NSString *entry_name(const DFSENTRY *e)
{
	return from_sjis(e->display);
}

static NSString *size_text(uint64_t bytes)
{
	return [NSByteCountFormatter stringFromByteCount:(long long)bytes countStyle:NSByteCountFormatterCountStyleFile];
}

static NSString *error_text(int error)
{
	return [NSString stringWithFormat:@"%@（%d）", [NSString stringWithUTF8String:dfs_strerror(error)], error];
}

static NSString *data_dir(void)
{
	return [NSFileManager defaultManager].currentDirectoryPath;
}

static NSString *absolute_path(NSString *path)
{
	if (!path.isAbsolutePath) {
		path = [data_dir() stringByAppendingPathComponent:path];
	}
	return path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
}

// ---- disks

@interface NP2DiskRef : NSObject
@property (nonatomic, copy) NSString *path;		/* as the emulator has it (relative to the data directory) */
@property (nonatomic, copy) NSString *slot;		/* "FDD1", "SCSI #0", ... or nil when not in use */
@property (nonatomic) int fddDrive;				/* in use as this floppy drive, or -1 */
@property (nonatomic) BOOL hddInUse;
@end

@implementation NP2DiskRef
- (NSString *)name
{
	return self.path.lastPathComponent;
}
@end

static const struct {
	REG8		drv;
	const char	*label;
} s_hddslots[] = {
	{0x00, "IDE #1"},
	{0x01, "IDE #2"},
	{0x20, "SCSI #0"},
	{0x21, "SCSI #1"},
	{0x22, "SCSI #2"},
	{0x23, "SCSI #3"},
};

/* In boot order: the hard disks, IDE / SASI first. */
static NSArray<NP2DiskRef *> *hdds_in_use(void)
{
	NSMutableArray<NP2DiskRef *> *list = [NSMutableArray array];
	for (size_t i = 0; i < NELEMENTS(s_hddslots); i++) {
		REG8 drv = s_hddslots[i].drv;
		if (!(drv & 0x20) && np2cfg.idetype[drv & 0x0f] != SXSIDEV_HDD) {
			continue;
		}
		const OEMCHAR *name = diskdrv_getsxsi(drv);
		if (name == NULL || name[0] == '\0') {
			continue;
		}
		NP2DiskRef *ref = [NP2DiskRef new];
		ref.path = [NSString stringWithUTF8String:name];
		ref.slot = [NSString stringWithUTF8String:s_hddslots[i].label];
		ref.fddDrive = -1;
		ref.hddInUse = YES;
		[list addObject:ref];
	}
	return list;
}

static NSArray<NP2DiskRef *> *disks_in_use(void)
{
	NSMutableArray<NP2DiskRef *> *list = [NSMutableArray array];
	for (REG8 drive = 0; drive < 2; drive++) {
		const OEMCHAR *name = fdd_diskname(drive);
		if (name == NULL || name[0] == '\0') {
			continue;
		}
		NP2DiskRef *ref = [NP2DiskRef new];
		ref.path = [NSString stringWithUTF8String:name];
		ref.slot = [NSString stringWithFormat:@"FDD%d", drive + 1];
		ref.fddDrive = drive;
		[list addObject:ref];
	}
	[list addObjectsFromArray:hdds_in_use()];
	return list;
}

static BOOL is_image_name(NSString *name)
{
	static NSSet<NSString *> *extensions;
	if (extensions == nil) {
		extensions = [NSSet setWithArray:@[ @"hdd", @"nhd", @"hdi", @"thd", @"slh", @"hdn", @"hds",
		                                    @"d88", @"88d", @"d98", @"98d", @"fdi", @"hdm", @"xdf",
		                                    @"dup", @"tfd", @"img", @"ima", @"2hd", @"flp" ]];
	}
	return [extensions containsObject:name.pathExtension.lowercaseString];
}

/* The images in the data directory (and folders in it, not the host
 * drive's) other than those in use. */
static NSArray<NP2DiskRef *> *other_disks(NSArray<NP2DiskRef *> *inUse)
{
	NSMutableSet<NSString *> *used = [NSMutableSet set];
	for (NP2DiskRef *ref in inUse) {
		[used addObject:absolute_path(ref.path)];
	}
	NSMutableArray<NP2DiskRef *> *list = [NSMutableArray array];
	NSString *root = data_dir();
	NSDirectoryEnumerator<NSString *> *e = [[NSFileManager defaultManager] enumeratorAtPath:root];
	for (NSString *relative in e) {
		if (e.level > 2 || [relative hasPrefix:kHostDriveDir] || [relative isEqualToString:@"hostdrv"]) {
			[e skipDescendants];
			continue;
		}
		if (!is_image_name(relative) || [used containsObject:absolute_path(relative)]) {
			continue;
		}
		NP2DiskRef *ref = [NP2DiskRef new];
		ref.path = relative;
		ref.fddDrive = -1;
		[list addObject:ref];
	}
	[list sortUsingComparator:^NSComparisonResult(NP2DiskRef *a, NP2DiskRef *b) {
		return [a.path localizedStandardCompare:b.path];
	}];
	return list;
}

// ---- a disk being edited

@interface NP2DiskSession : NSObject
@property (nonatomic, strong, readonly) NP2DiskRef *disk;
@property (nonatomic) BOOL modified;
@property (nonatomic) int volume;
@end

@implementation NP2DiskSession {
	BOOL _floppyRemoved;
	BOOL _floppyProtected;
}

- (instancetype)initWithDisk:(NP2DiskRef *)disk
{
	self = [super init];
	if (self) {
		_disk = disk;
		if (disk.fddDrive >= 0) {
			_floppyProtected = fdd_diskprotect((REG8)disk.fddDrive);
			diskdrv_setfdd((REG8)disk.fddDrive, NULL, 0);
			_floppyRemoved = YES;
		}
	}
	return self;
}

/* Runs body with the image open; returns its result, or the error of
 * opening it. */
- (int)withImage:(BOOL)write do:(int (^)(DFSIMAGE *image))body
{
	if (self.disk.hddInUse) {
		sxsi_allflash();
	}
	int error = DFS_OK;
	DFSIMAGE *image = dfs_open(absolute_path(self.disk.path).fileSystemRepresentation, write, &error);
	if (image == NULL) {
		return error;
	}
	if (write && !dfs_iswritable(image)) {
		dfs_close(image);
		return DFS_EROFS;
	}
	int r = body(image);
	dfs_close(image);
	if (write && r >= 0) {
		self.modified = YES;
	}
	return r;
}

- (int)withVolume:(BOOL)write do:(int (^)(DFSVOLUME *volume))body
{
	int index = self.volume;
	return [self withImage:write do:^int(DFSIMAGE *image) {
		DFSVOLUME *volume = dfs_volume(image, index);
		return volume ? body(volume) : DFS_EFORMAT;
	}];
}

/* Puts a floppy back; the caller resets for a hard disk (it may ask). */
- (void)finish
{
	if (_floppyRemoved) {
		diskdrv_setfdd((REG8)self.disk.fddDrive, self.disk.path.fileSystemRepresentation, _floppyProtected ? 1 : 0);
		_floppyRemoved = NO;
	}
}

- (BOOL)needsReset
{
	return self.disk.hddInUse && self.modified;
}

@end

// ---- common

static void show_message(UIViewController *host, NSString *title, NSString *message)
{
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
	                                                        preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	[host presentViewController:alert animated:YES completion:nil];
}

static void show_error(UIViewController *host, int error)
{
	show_message(host, @"できませんでした", error_text(error));
}

static void ask_name(UIViewController *host, NSString *title, NSString *initial, void (^done)(NSString *name))
{
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
	                                                               message:@"8 文字 + 拡張子 3 文字まで（全角は 2 文字分）"
	                                                        preferredStyle:UIAlertControllerStyleAlert];
	[alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
		field.text = initial;
		field.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
		field.autocorrectionType = UITextAutocorrectionTypeNo;
	}];
	__weak UIAlertController *weakAlert = alert;
	[alert addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
	[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
		(void)action;
		NSString *name = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
		if (name.length) {
			done(name);
		}
	}]];
	[host presentViewController:alert animated:YES completion:nil];
}

static void now_dostime(uint16_t *date, uint16_t *time)
{
	dfs_dostime((int64_t)NSDate.date.timeIntervalSince1970, date, time);
}

// ---- copying in and out

typedef struct {
	int		added;
	int		skipped;
	int		error;
} IMPORTRESULT;

/* Adds a host file or folder (recursively) to dir. Same names are replaced
 * when replace is set, else skipped. */
static void import_item(DFSVOLUME *volume, uint32_t dir, NSURL *url, BOOL replace, IMPORTRESULT *result)
{
	NSNumber *isDir = nil;
	[url getResourceValue:&isDir forKey:NSURLIsDirectoryKey error:nil];
	NSDate *modified = nil;
	[url getResourceValue:&modified forKey:NSURLContentModificationDateKey error:nil];
	uint16_t date, time;
	dfs_dostime((int64_t)(modified ?: NSDate.date).timeIntervalSince1970, &date, &time);

	NSData *longname = to_sjis(url.lastPathComponent);
	uint8_t name[11];
	int same = dfs_uniquename(volume, dir, longname.bytes, name);
	if (same < 0) {
		result->error = same;
		return;
	}
	DFSENTRY existing;
	BOOL exists = (dfs_find(volume, dir, name, &existing) == DFS_OK);

	if (isDir.boolValue) {
		uint32_t cluster = 0;
		if (exists) {
			if (!(existing.attr & DFS_ATTR_DIRECTORY)) {
				result->skipped++;
				return;
			}
			cluster = existing.cluster;
		}
		else {
			int r = dfs_mkdir(volume, dir, name, date, time, &cluster);
			if (r != DFS_OK) {
				NSLog(@"diskedit: mkdir %@: %d", url.lastPathComponent, r);
				result->error = r;
				return;
			}
		}
		NSArray<NSURL *> *children = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:url
		                                                           includingPropertiesForKeys:@[ NSURLIsDirectoryKey, NSURLContentModificationDateKey ]
		                                                                              options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
		for (NSURL *child in children) {
			import_item(volume, cluster, child, replace, result);
			if (result->error) {
				return;
			}
		}
		return;
	}
	if (exists && (!replace || (existing.attr & DFS_ATTR_DIRECTORY))) {
		result->skipped++;
		return;
	}
	NSError *readError = nil;
	NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&readError];
	if (data == nil || data.length > UINT32_MAX) {
		NSLog(@"diskedit: cannot read %@: %@", url.path, readError);
		result->error = DFS_EIO;
		return;
	}
	int r = dfs_writefile(volume, dir, name, data.bytes, (uint32_t)data.length, date, time);
	if (r != DFS_OK) {
		NSLog(@"diskedit: write %@: %d", url.lastPathComponent, r);
		result->error = r;
		return;
	}
	result->added++;
}

/* Would any of these replace something in dir? (only the top level) */
static int count_existing(DFSVOLUME *volume, uint32_t dir, NSArray<NSURL *> *urls)
{
	int n = 0;
	for (NSURL *url in urls) {
		uint8_t name[11];
		if (dfs_uniquename(volume, dir, to_sjis(url.lastPathComponent).bytes, name) == 1 &&
		    dfs_find(volume, dir, name, NULL) == DFS_OK) {
			n++;
		}
	}
	return n;
}

static int remove_recursive(DFSVOLUME *volume, uint32_t dir, const DFSENTRY *entry)
{
	if (entry->attr & DFS_ATTR_DIRECTORY) {
		DFSENTRY *children = NULL;
		int count = 0;
		int r = dfs_listdir(volume, entry->cluster, &children, &count);
		for (int i = 0; r == DFS_OK && i < count; i++) {
			r = remove_recursive(volume, entry->cluster, &children[i]);
		}
		free(children);
		if (r != DFS_OK) {
			return r;
		}
	}
	return dfs_remove(volume, dir, entry->name);
}

/* Writes a file or folder out to a host folder. */
static int export_item(DFSVOLUME *volume, const DFSENTRY *entry, NSString *into)
{
	NSString *path = [into stringByAppendingPathComponent:entry_name(entry)];
	NSDate *date = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)dfs_unixtime(entry->date, entry->time)];
	if (entry->attr & DFS_ATTR_DIRECTORY) {
		[[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
		DFSENTRY *children = NULL;
		int count = 0;
		int r = dfs_listdir(volume, entry->cluster, &children, &count);
		for (int i = 0; r == DFS_OK && i < count; i++) {
			r = export_item(volume, &children[i], path);
		}
		free(children);
		return r;
	}
	uint8_t *data = NULL;
	uint32_t size = 0;
	int r = dfs_readfile(volume, entry, &data, &size);
	if (r != DFS_OK) {
		return r;
	}
	NSData *contents = [NSData dataWithBytesNoCopy:data length:size freeWhenDone:YES];
	if (![contents writeToFile:path atomically:YES]) {
		return DFS_EIO;
	}
	[[NSFileManager defaultManager] setAttributes:@{ NSFileModificationDate: date } ofItemAtPath:path error:nil];
	return DFS_OK;
}

// ---- the files of a directory

@interface NP2DiskBrowser : UITableViewController <UIDocumentPickerDelegate>
- (instancetype)initWithSession:(NP2DiskSession *)session dir:(uint32_t)dir title:(NSString *)title;
- (void)importURLs:(NSArray<NSURL *> *)urls;
- (void)makeFolder:(NSString *)name;
- (void)deleteEntryNamed:(NSString *)name confirm:(BOOL)confirm;
@end

@implementation NP2DiskBrowser {
	NP2DiskSession *_session;
	uint32_t _dir;
	NSArray<NSValue *> *_entries;		/* DFSENTRY */
	NSString *_footer;
	BOOL _writable;
}

- (instancetype)initWithSession:(NP2DiskSession *)session dir:(uint32_t)dir title:(NSString *)title
{
	self = [super initWithStyle:UITableViewStyleInsetGrouped];
	if (self) {
		_session = session;
		_dir = dir;
		self.title = title;
	}
	return self;
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	__weak NP2DiskBrowser *weakSelf = self;
	UIAction *importFiles = [UIAction actionWithTitle:@"ファイルを取り込む…" image:[UIImage systemImageNamed:@"doc.badge.plus"]
	                                       identifier:nil handler:^(UIAction *action) {
		(void)action;
		[weakSelf pickWithTypes:@[ UTTypeItem ]];
	}];
	UIAction *importFolder = [UIAction actionWithTitle:@"フォルダごと取り込む…" image:[UIImage systemImageNamed:@"folder.badge.plus"]
	                                        identifier:nil handler:^(UIAction *action) {
		(void)action;
		[weakSelf pickWithTypes:@[ UTTypeFolder ]];
	}];
	UIAction *newFolder = [UIAction actionWithTitle:@"新しいフォルダ" image:[UIImage systemImageNamed:@"folder"]
	                                     identifier:nil handler:^(UIAction *action) {
		(void)action;
		NP2DiskBrowser *strongSelf = weakSelf;
		if (strongSelf) {
			ask_name(strongSelf, @"新しいフォルダ", @"", ^(NSString *name) {
				[weakSelf makeFolder:name];
			});
		}
	}];
	UIBarButtonItem *add = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus"]
	                                                         menu:[UIMenu menuWithChildren:@[ importFiles, importFolder, newFolder ]]];
	add.accessibilityLabel = @"追加";
	self.navigationItem.rightBarButtonItem = add;
	[self reload];
}

- (void)reload
{
	__block NSMutableArray<NSValue *> *list = [NSMutableArray array];
	__block DFSVOLUMEINFO info;
	uint32_t dir = _dir;
	__block BOOL writable = NO;
	int r = [_session withImage:NO do:^int(DFSIMAGE *image) {
		DFSVOLUME *volume = dfs_volume(image, self->_session.volume);
		if (volume == NULL) {
			return DFS_EFORMAT;
		}
		DFSENTRY *entries = NULL;
		int count = 0;
		int r = dfs_listdir(volume, dir, &entries, &count);
		for (int i = 0; i < count; i++) {
			[list addObject:[NSValue valueWithBytes:&entries[i] objCType:@encode(DFSENTRY)]];
		}
		free(entries);
		dfs_volumeinfo(volume, &info);
		return r;
	}];
	/* writable: the file can be opened for writing (and a D88 is not protected) */
	[_session withImage:YES do:^int(DFSIMAGE *image) {
		(void)image;
		writable = YES;
		return DFS_EINVAL;		/* nothing was changed */
	}];
	_writable = writable;
	self.navigationItem.rightBarButtonItem.enabled = writable;
	[list sortUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
		DFSENTRY ea, eb;
		[a getValue:&ea];
		[b getValue:&eb];
		BOOL da = (ea.attr & DFS_ATTR_DIRECTORY) != 0;
		BOOL db = (eb.attr & DFS_ATTR_DIRECTORY) != 0;
		if (da != db) {
			return da ? NSOrderedAscending : NSOrderedDescending;
		}
		return [entry_name(&ea) compare:entry_name(&eb)];
	}];
	_entries = list;
	if (r == DFS_OK) {
		_footer = [NSString stringWithFormat:@"%lu 項目 · 空き %@ / %@ · FAT%d%@", (unsigned long)list.count,
		           size_text(info.freebytes), size_text(info.totalbytes), info.fattype, writable ? @"" : @" · 読み込み専用"];
	}
	else {
		_footer = error_text(r);
	}
	[self.tableView reloadData];
}

- (DFSENTRY)entryAt:(NSIndexPath *)indexPath
{
	DFSENTRY entry;
	[_entries[(NSUInteger)indexPath.row] getValue:&entry];
	return entry;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
	(void)tableView;
	(void)section;
	return (NSInteger)_entries.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
	(void)tableView;
	(void)section;
	return _footer;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"entry"]
		?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"entry"];
	DFSENTRY entry = [self entryAt:indexPath];
	BOOL isDir = (entry.attr & DFS_ATTR_DIRECTORY) != 0;
	UIListContentConfiguration *content = cell.defaultContentConfiguration;
	content.text = entry_name(&entry);
	content.textProperties.font = [UIFont monospacedSystemFontOfSize:17 weight:UIFontWeightRegular];
	content.image = [UIImage systemImageNamed:isDir ? @"folder.fill" : @"doc"];
	NSDate *date = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)dfs_unixtime(entry.date, entry.time)];
	NSString *when = [NSDateFormatter localizedStringFromDate:date dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle];
	content.secondaryText = isDir ? when : [NSString stringWithFormat:@"%@ · %@", size_text(entry.size), when];
	content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
	cell.contentConfiguration = content;
	cell.accessoryType = isDir ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
	DFSENTRY entry = [self entryAt:indexPath];
	if (entry.attr & DFS_ATTR_DIRECTORY) {
		NP2DiskBrowser *child = [[NP2DiskBrowser alloc] initWithSession:_session dir:entry.cluster title:entry_name(&entry)];
		[self.navigationController pushViewController:child animated:YES];
		return;
	}
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	[self exportEntry:entry from:[tableView cellForRowAtIndexPath:indexPath]];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point
{
	(void)point;
	DFSENTRY entry = [self entryAt:indexPath];
	__weak NP2DiskBrowser *weakSelf = self;
	__weak UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
	BOOL writable = _writable;
	return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
		(void)suggested;
		NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
		[items addObject:[UIAction actionWithTitle:@"書き出す…" image:[UIImage systemImageNamed:@"square.and.arrow.up"]
		                                identifier:nil handler:^(UIAction *action) {
			(void)action;
			[weakSelf exportEntry:entry from:cell];
		}]];
		if (writable) {
			[items addObject:[UIAction actionWithTitle:@"名前を変更" image:[UIImage systemImageNamed:@"pencil"]
			                                identifier:nil handler:^(UIAction *action) {
				(void)action;
				[weakSelf renameEntry:entry];
			}]];
			UIAction *remove = [UIAction actionWithTitle:@"削除" image:[UIImage systemImageNamed:@"trash"]
			                                  identifier:nil handler:^(UIAction *action) {
				(void)action;
				[weakSelf deleteEntryNamed:entry_name(&entry) confirm:YES];
			}];
			remove.attributes = UIMenuElementAttributesDestructive;
			[items addObject:remove];
		}
		return [UIMenu menuWithChildren:items];
	}];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
	(void)tableView;
	if (!_writable) {
		return nil;
	}
	DFSENTRY entry = [self entryAt:indexPath];
	__weak NP2DiskBrowser *weakSelf = self;
	UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"削除"
	                                                                   handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
		(void)action;
		(void)view;
		[weakSelf deleteEntryNamed:entry_name(&entry) confirm:YES];
		done(YES);
	}];
	return [UISwipeActionsConfiguration configurationWithActions:@[ remove ]];
}

// ---- actions

- (void)pickWithTypes:(NSArray<UTType *> *)types
{
	UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:NO];
	picker.allowsMultipleSelection = YES;
	picker.delegate = self;
	[self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
	(void)controller;
	[self importURLs:urls];
}

- (void)importURLs:(NSArray<NSURL *> *)urls
{
	for (NSURL *url in urls) {
		[url startAccessingSecurityScopedResource];
	}
	uint32_t dir = _dir;
	__block int existing = 0;
	[_session withVolume:NO do:^int(DFSVOLUME *volume) {
		existing = count_existing(volume, dir, urls);
		return DFS_OK;
	}];
	if (existing == 0) {
		[self importURLs:urls replace:NO];
		return;
	}
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"同じ名前があります"
	                                                               message:[NSString stringWithFormat:@"%d 個の項目と同じ名前のものがディスクにあります。置き換えますか？", existing]
	                                                        preferredStyle:UIAlertControllerStyleAlert];
	__weak NP2DiskBrowser *weakSelf = self;
	[alert addAction:[UIAlertAction actionWithTitle:@"置き換えない" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
		(void)action;
		[weakSelf importURLs:urls replace:NO];
	}]];
	[alert addAction:[UIAlertAction actionWithTitle:@"置き換える" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
		(void)action;
		[weakSelf importURLs:urls replace:YES];
	}]];
	[self presentViewController:alert animated:YES completion:nil];
}

- (void)importURLs:(NSArray<NSURL *> *)urls replace:(BOOL)replace
{
	uint32_t dir = _dir;
	__block IMPORTRESULT result = {0, 0, 0};
	int r = [_session withVolume:YES do:^int(DFSVOLUME *volume) {
		for (NSURL *url in urls) {
			import_item(volume, dir, url, replace, &result);
			if (result.error) {
				break;
			}
		}
		return result.error;
	}];
	for (NSURL *url in urls) {
		[url stopAccessingSecurityScopedResource];
	}
	NSLog(@"diskedit: imported %d, skipped %d, error %d", result.added, result.skipped, r);
	[self reload];
	if (r != DFS_OK) {
		show_message(self, @"取り込めませんでした", [NSString stringWithFormat:@"%@（%d 個は取り込み済み）", error_text(r), result.added]);
	}
	else if (result.skipped) {
		show_message(self, @"取り込みました", [NSString stringWithFormat:@"%d 個は同じ名前があったので取り込んでいません。", result.skipped]);
	}
}

- (void)makeFolder:(NSString *)name
{
	uint32_t dir = _dir;
	int r = [_session withVolume:YES do:^int(DFSVOLUME *volume) {
		uint8_t n83[11];
		int ok = dfs_shortname(to_sjis(name).bytes, n83);
		if (ok < 0) {
			return ok;
		}
		uint16_t date, time;
		now_dostime(&date, &time);
		return dfs_mkdir(volume, dir, n83, date, time, NULL);
	}];
	[self reload];
	if (r != DFS_OK) {
		show_error(self, r);
	}
}

- (void)renameEntry:(DFSENTRY)entry
{
	__weak NP2DiskBrowser *weakSelf = self;
	uint32_t dir = _dir;
	ask_name(self, @"名前を変更", entry_name(&entry), ^(NSString *name) {
		NP2DiskBrowser *strongSelf = weakSelf;
		if (strongSelf == nil) {
			return;
		}
		int r = [strongSelf->_session withVolume:YES do:^int(DFSVOLUME *volume) {
			uint8_t n83[11];
			int ok = dfs_shortname(to_sjis(name).bytes, n83);
			return ok < 0 ? ok : dfs_rename(volume, dir, entry.name, n83);
		}];
		[strongSelf reload];
		if (r != DFS_OK) {
			show_error(strongSelf, r);
		}
	});
}

- (void)deleteEntryNamed:(NSString *)name confirm:(BOOL)confirm
{
	NSUInteger index = [_entries indexOfObjectPassingTest:^BOOL(NSValue *value, NSUInteger i, BOOL *stop) {
		(void)i;
		(void)stop;
		DFSENTRY e;
		[value getValue:&e];
		return [entry_name(&e) isEqualToString:name];
	}];
	if (index == NSNotFound) {
		return;
	}
	DFSENTRY entry;
	[_entries[index] getValue:&entry];
	if (confirm) {
		BOOL isDir = (entry.attr & DFS_ATTR_DIRECTORY) != 0;
		UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"「%@」を削除しますか？", name]
		                                                               message:isDir ? @"中のファイルもすべて削除されます。" : nil
		                                                        preferredStyle:UIAlertControllerStyleAlert];
		__weak NP2DiskBrowser *weakSelf = self;
		[alert addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
		[alert addAction:[UIAlertAction actionWithTitle:@"削除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
			(void)action;
			[weakSelf deleteEntryNamed:name confirm:NO];
		}]];
		[self presentViewController:alert animated:YES completion:nil];
		return;
	}
	uint32_t dir = _dir;
	int r = [_session withVolume:YES do:^int(DFSVOLUME *volume) {
		return remove_recursive(volume, dir, &entry);
	}];
	[self reload];
	if (r != DFS_OK) {
		show_error(self, r);
	}
}

/* Out through the share sheet ("Save to Files", AirDrop, other apps). */
- (void)exportEntry:(DFSENTRY)entry from:(UIView *)view
{
	NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
	[[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
	int r = [_session withVolume:NO do:^int(DFSVOLUME *volume) {
		return export_item(volume, &entry, dir);
	}];
	if (r != DFS_OK) {
		show_error(self, r);
		return;
	}
	NSURL *url = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:entry_name(&entry)]];
	UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[ url ] applicationActivities:nil];
	share.popoverPresentationController.sourceView = view ?: self.view;
	share.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray *items, NSError *error) {
		(void)type;
		(void)completed;
		(void)items;
		(void)error;
		[[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
	};
	[self presentViewController:share animated:YES completion:nil];
}

@end

// ---- partitions

@interface NP2VolumeList : UITableViewController
@end

@implementation NP2VolumeList {
	NP2DiskSession *_session;
	NSArray<NSString *> *_titles;
	NSArray<NSString *> *_details;
}

- (instancetype)initWithSession:(NP2DiskSession *)session
{
	self = [super initWithStyle:UITableViewStyleInsetGrouped];
	if (self) {
		_session = session;
		self.title = session.disk.name;
		NSMutableArray *titles = [NSMutableArray array];
		NSMutableArray *details = [NSMutableArray array];
		[session withImage:NO do:^int(DFSIMAGE *image) {
			for (int i = 0; i < dfs_volumecount(image); i++) {
				DFSVOLUMEINFO info;
				dfs_volumeinfo(dfs_volume(image, i), &info);
				NSString *name = info.name[0] ? from_sjis(info.name) : (info.label[0] ? from_sjis(info.label) : @"");
				[titles addObject:[NSString stringWithFormat:@"区画 %d%@%@", i + 1, name.length ? @"  " : @"", name]];
				[details addObject:[NSString stringWithFormat:@"FAT%d · %@", info.fattype, size_text(info.totalbytes)]];
			}
			return DFS_OK;
		}];
		_titles = titles;
		_details = details;
	}
	return self;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
	(void)tableView;
	(void)section;
	return (NSInteger)_titles.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
	(void)tableView;
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
	UIListContentConfiguration *content = [UIListContentConfiguration valueCellConfiguration];
	content.text = _titles[(NSUInteger)indexPath.row];
	content.secondaryText = _details[(NSUInteger)indexPath.row];
	cell.contentConfiguration = content;
	cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
	(void)tableView;
	_session.volume = (int)indexPath.row;
	NP2DiskBrowser *browser = [[NP2DiskBrowser alloc] initWithSession:_session dir:0 title:_titles[(NSUInteger)indexPath.row]];
	[self.navigationController pushViewController:browser animated:YES];
}

@end

// ---- the disks

@interface NP2DiskList : UITableViewController
@property (nonatomic, weak) UIViewController *host;
- (void)openDiskTitled:(NSString *)title;
- (void)done;
@end

@implementation NP2DiskList {
	NSArray<NP2DiskRef *> *_inUse;
	NSArray<NP2DiskRef *> *_others;
	NP2DiskSession *_session;
	BOOL _needsReset;
}

- (instancetype)init
{
	self = [super initWithStyle:UITableViewStyleInsetGrouped];
	if (self) {
		self.title = @"ディスクの中身";
	}
	return self;
}

- (void)viewWillAppear:(BOOL)animated
{
	[super viewWillAppear:animated];
	[self endSession];
	_inUse = disks_in_use();
	_others = other_disks(_inUse);
	[self.tableView reloadData];
}

- (void)endSession
{
	if (_session) {
		_needsReset |= _session.needsReset;
		[_session finish];
		_session = nil;
	}
}

- (void)done
{
	[self endSession];
	BOOL reset = _needsReset;
	UIViewController *host = self.host;
	[self.navigationController dismissViewControllerAnimated:YES completion:^{
		if (reset) {
			keybar_resetmachine();
			show_message(host, @"PC-98 をリセットしました", @"使用中のハードディスクを変更したため、リセットして読み込み直しました。");
		}
	}];
}

- (NSArray<NP2DiskRef *> *)disksIn:(NSInteger)section
{
	return section == 0 ? _inUse : _others;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
	(void)tableView;
	return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
	(void)tableView;
	return (NSInteger)MAX([self disksIn:section].count, 1u);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
	(void)tableView;
	return section == 0 ? @"PC-98 で使用中" : @"データフォルダ";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
	(void)tableView;
	return section == 0 ? @"フロッピーは編集のあいだ取り出し、閉じると入れ直します。ハードディスクを変更した場合は、閉じたときに PC-98 をリセットします。" : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
	(void)tableView;
	UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
	UIListContentConfiguration *content = [UIListContentConfiguration valueCellConfiguration];
	NSArray<NP2DiskRef *> *disks = [self disksIn:indexPath.section];
	if (disks.count == 0) {
		content.text = @"なし";
		content.textProperties.color = UIColor.secondaryLabelColor;
		cell.selectionStyle = UITableViewCellSelectionStyleNone;
	}
	else {
		NP2DiskRef *disk = disks[(NSUInteger)indexPath.row];
		content.text = disk.name;
		content.secondaryText = disk.slot ?: disk.path.stringByDeletingLastPathComponent;
		content.image = [UIImage systemImageNamed:(disk.fddDrive >= 0 || [@[ @"d88", @"88d", @"d98", @"98d", @"fdi", @"hdm", @"xdf", @"dup", @"tfd", @"img", @"ima", @"2hd", @"flp" ] containsObject:disk.path.pathExtension.lowercaseString])
		                                          ? @"opticaldiscdrive" : @"internaldrive"];
		cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
	}
	cell.contentConfiguration = content;
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	NSArray<NP2DiskRef *> *disks = [self disksIn:indexPath.section];
	if (disks.count == 0) {
		return;
	}
	[self openDisk:disks[(NSUInteger)indexPath.row]];
}

- (void)openDiskTitled:(NSString *)title
{
	for (NP2DiskRef *disk in [_inUse arrayByAddingObjectsFromArray:_others]) {
		if ([disk.name isEqualToString:title]) {
			[self openDisk:disk];
			return;
		}
	}
	NSLog(@"diskedit: no disk %@", title);
}

- (void)openDisk:(NP2DiskRef *)disk
{
	[self endSession];
	NP2DiskSession *session = [[NP2DiskSession alloc] initWithDisk:disk];
	__block int count = 0;
	int r = [session withImage:NO do:^int(DFSIMAGE *image) {
		count = dfs_volumecount(image);
		return DFS_OK;
	}];
	if (r != DFS_OK) {
		[session finish];
		show_message(self, @"開けません", error_text(r));
		return;
	}
	_session = session;
	UIViewController *next = (count > 1) ? [[NP2VolumeList alloc] initWithSession:session]
	                                     : [[NP2DiskBrowser alloc] initWithSession:session dir:0 title:disk.name];
	[self.navigationController pushViewController:next animated:YES];
}

@end

static __weak NP2DiskList *s_list;

void diskedit_present(UIViewController *host)
{
	NP2DiskList *list = [NP2DiskList new];
	list.host = host;
	UINavigationController *nav = [[NP2PausingNavigationController alloc] initWithRootViewController:list];
	__weak NP2DiskList *weakList = list;
	list.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone primaryAction:[UIAction actionWithHandler:^(UIAction *action) {
		(void)action;
		[weakList done];
	}] menu:nil];
	nav.modalPresentationStyle = UIModalPresentationFormSheet;
	nav.modalInPresentation = YES;		/* closed with Done only, which finishes up */
	s_list = list;
	[host presentViewController:nav animated:YES completion:nil];
}

// ---- host drive setup

/* Text files are kept as bytes (Latin-1 maps each byte to one character),
 * so that Shift_JIS in them is left as it was. */
static NSString *bytes_text(NSData *data)
{
	NSString *text = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] ?: @"";
	NSRange eof = [text rangeOfString:@"\x1a"];
	return (eof.location != NSNotFound) ? [text substringToIndex:eof.location] : text;
}

static NSArray<NSString *> *text_lines(NSString *text)
{
	NSMutableArray<NSString *> *lines = [[[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
	                                      componentsSeparatedByString:@"\n"] mutableCopy];
	if (lines.count && lines.lastObject.length == 0) {
		[lines removeLastObject];
	}
	return lines;
}

static NSData *lines_data(NSArray<NSString *> *lines)
{
	NSString *text = [[lines componentsJoinedByString:@"\r\n"] stringByAppendingString:@"\r\n"];
	return [text dataUsingEncoding:NSISOLatin1StringEncoding];
}

static NSRegularExpression *regex(NSString *pattern)
{
	return [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
}

static BOOL line_matches(NSString *line, NSRegularExpression *re)
{
	return [re firstMatchInString:line options:0 range:NSMakeRange(0, line.length)] != nil;
}

static void short_name(NSString *name, uint8_t n83[11])
{
	dfs_shortname(name.UTF8String, n83);
}

static NSData *read_text_file(DFSVOLUME *volume, NSString *name, BOOL *exists)
{
	uint8_t n83[11];
	short_name(name, n83);
	DFSENTRY entry;
	*exists = NO;
	if (dfs_find(volume, 0, n83, &entry) != DFS_OK || (entry.attr & DFS_ATTR_DIRECTORY)) {
		return nil;
	}
	uint8_t *data = NULL;
	uint32_t size = 0;
	if (dfs_readfile(volume, &entry, &data, &size) != DFS_OK) {
		return nil;
	}
	*exists = YES;
	return [NSData dataWithBytesNoCopy:data length:size freeWhenDone:YES];
}

static int write_root_file(DFSVOLUME *volume, NSString *name, NSData *data)
{
	uint8_t n83[11];
	short_name(name, n83);
	uint16_t date, time;
	now_dostime(&date, &time);
	return dfs_writefile(volume, 0, n83, data.bytes, (uint32_t)data.length, date, time);
}

/* The volume that boots: the first with a CONFIG.SYS / AUTOEXEC.BAT / a DOS. */
static DFSVOLUME *boot_volume(DFSIMAGE *image)
{
	for (int i = 0; i < dfs_volumecount(image); i++) {
		DFSVOLUME *volume = dfs_volume(image, i);
		for (NSString *name in @[ @"CONFIG.SYS", @"FDCONFIG.SYS", @"AUTOEXEC.BAT", @"COMMAND.COM", @"IO.SYS", @"KERNEL.SYS" ]) {
			uint8_t n83[11];
			short_name(name, n83);
			if (dfs_find(volume, 0, n83, NULL) == DFS_OK) {
				return volume;
			}
		}
	}
	return dfs_volume(image, 0);
}

/* The changes made to the boot disk (in words for the user), or nil and
 * *error. */
static NSArray<NSString *> *install_hostdrv(DFSVOLUME *volume, int *error)
{
	NSMutableArray<NSString *> *changes = [NSMutableArray array];
	*error = DFS_OK;

	/* CONFIG.SYS: FreeDOS reads FDCONFIG.SYS when there is one */
	BOOL exists = NO;
	NSString *configName = @"FDCONFIG.SYS";
	NSData *config = read_text_file(volume, configName, &exists);
	if (!exists) {
		configName = @"CONFIG.SYS";
		config = read_text_file(volume, configName, &exists);
	}
	NSMutableArray<NSString *> *configLines = [text_lines(bytes_text(config ?: [NSData data])) mutableCopy];

	/* the batch file run at start: SHELL=... /P=FILE, else AUTOEXEC.BAT */
	NSString *autoexecName = @"AUTOEXEC.BAT";
	NSRegularExpression *shellRe = regex(@"^\\s*(?:[0-9]*\\?)?SHELL(?:HIGH)?\\s*=.*\\s/P[=:]([^\\s]+)");
	for (NSString *line in configLines) {
		NSTextCheckingResult *m = [shellRe firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
		if (m) {
			NSString *file = [line substringWithRange:[m rangeAtIndex:1]];
			file = [file componentsSeparatedByString:@"\\"].lastObject;
			if (file.length) {
				autoexecName = file.uppercaseString;
			}
		}
	}

	/* LASTDRIVE=Z: HOSTDRV needs the drive letter to exist */
	NSRegularExpression *lastRe = regex(@"^(\\s*(?:[0-9]*\\?)?LASTDRIVE(?:HIGH)?\\s*=\\s*)([A-Za-z])");
	BOOL hasLast = NO;
	BOOL configChanged = NO;
	for (NSUInteger i = 0; i < configLines.count; i++) {
		NSString *line = configLines[i];
		NSTextCheckingResult *m = [lastRe firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
		if (m == nil) {
			continue;
		}
		hasLast = YES;
		NSString *letter = [line substringWithRange:[m rangeAtIndex:2]].uppercaseString;
		if (![letter isEqualToString:@"Z"]) {
			configLines[i] = [line stringByReplacingCharactersInRange:[m rangeAtIndex:2] withString:@"Z"];
			configChanged = YES;
		}
	}
	if (!hasLast) {
		[configLines addObject:@"LASTDRIVE=Z"];
		configChanged = YES;
	}

	/* AUTOEXEC.BAT: HOSTDRV Z, near the top so that it runs before a
	 * program that does not return */
	NSData *autoexec = read_text_file(volume, autoexecName, &exists);
	NSMutableArray<NSString *> *autoLines = [text_lines(bytes_text(autoexec ?: [NSData data])) mutableCopy];
	NSRegularExpression *hostdrvRe = regex(@"^\\s*@?\\s*(?:(?:LH|LOADHIGH)\\s+)?(?:[^\\s]*\\\\)?HOSTDRV(?:\\.COM)?(?:\\s|$)");
	BOOL hasHostdrv = NO;
	for (NSString *line in autoLines) {
		if (line_matches(line, hostdrvRe)) {
			hasHostdrv = YES;
		}
	}
	if (!hasHostdrv) {
		NSString *path = [NSBundle.mainBundle pathForResource:@"HOSTDRV" ofType:@"COM"];
		NSData *program = path ? [NSData dataWithContentsOfFile:path] : nil;
		if (program == nil) {
			*error = DFS_EIO;
			return nil;
		}
		*error = write_root_file(volume, @"HOSTDRV.COM", program);
		if (*error != DFS_OK) {
			return nil;
		}
		[changes addObject:@"HOSTDRV.COM をルートにコピー"];
		NSUInteger at = 0;
		if (autoLines.count && line_matches(autoLines[0], regex(@"^\\s*@?\\s*ECHO\\s+OFF\\s*$"))) {
			at = 1;
		}
		[autoLines insertObject:@"\\HOSTDRV.COM Z" atIndex:at];
		*error = write_root_file(volume, autoexecName, lines_data(autoLines));
		if (*error != DFS_OK) {
			return nil;
		}
		[changes addObject:[NSString stringWithFormat:@"%@ に「\\HOSTDRV.COM Z」を追加", autoexecName]];
	}
	if (configChanged) {
		*error = write_root_file(volume, configName, lines_data(configLines));
		if (*error != DFS_OK) {
			return nil;
		}
		[changes addObject:[NSString stringWithFormat:@"%@ を「LASTDRIVE=Z」に", configName]];
	}
	return changes;
}

static void enable_host_drive(void)
{
	np2cfg.hdrvenable = 1;
	if (np2cfg.hdrvroot[0] == '\0') {
		milstr_ncpy(np2cfg.hdrvroot, kHostDriveDir.UTF8String, NELEMENTS(np2cfg.hdrvroot));
	}
	np2cfg.hdrvacc = HDFMODE_READ | HDFMODE_WRITE | HDFMODE_DELETE;
	[[NSFileManager defaultManager] createDirectoryAtPath:absolute_path([NSString stringWithUTF8String:np2cfg.hdrvroot])
	                          withIntermediateDirectories:YES attributes:nil error:nil];
	settings_savenp2cfg();
}

static void run_hostdrv_setup(UIViewController *host)
{
	NP2DiskRef *disk = hdds_in_use().firstObject;
	NP2DiskSession *session = [[NP2DiskSession alloc] initWithDisk:disk];
	__block NSArray<NSString *> *changes = nil;
	int r = [session withImage:YES do:^int(DFSIMAGE *image) {
		int error = DFS_OK;
		changes = install_hostdrv(boot_volume(image), &error);
		return error;
	}];
	[session finish];
	NSLog(@"diskedit: hostdrv setup on %@: %d %@", disk.path, r, changes);
	if (r != DFS_OK) {
		show_message(host, @"組み込めませんでした", [NSString stringWithFormat:@"%@: %@", disk.name, error_text(r)]);
		return;
	}
	enable_host_drive();
	keybar_resetmachine();
	NSString *done = changes.count ? [NSString stringWithFormat:@"%@ に次の変更をしました。\n\n・%@", disk.name, [changes componentsJoinedByString:@"\n・"]]
	                               : [NSString stringWithFormat:@"%@ には組み込み済みでした。", disk.name];
	show_message(host, @"Z: ドライブを使えるようにしました",
	             [NSString stringWithFormat:@"%@\n\nPC-98 をリセットしました。起動すると、データフォルダの %@ が Z: になります。", done, kHostDriveDir]);
}

void diskedit_setuphostdrive(UIViewController *host)
{
	NP2DiskRef *disk = hdds_in_use().firstObject;
	if (disk == nil) {
		show_message(host, @"起動ディスクがありません", @"HOSTDRV はハードディスクに組み込みます。先にハードディスクのイメージを設定してください。");
		return;
	}
	NSString *message = [NSString stringWithFormat:
		@"起動ディスク「%@」（%@）に HOSTDRV を組み込みます。\n\n"
		@"・HOSTDRV.COM をルートにコピー\n"
		@"・AUTOEXEC.BAT に「\\HOSTDRV.COM Z」を追加\n"
		@"・CONFIG.SYS に「LASTDRIVE=Z」を追加\n"
		@"（済んでいるものはそのまま。FreeDOS は FDCONFIG.SYS）\n\n"
		@"ホストドライブを書き込み可で有効にして、PC-98 をリセットします。保存していないデータは失われます。",
		disk.name, disk.slot];
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Z: ドライブを使えるようにする"
	                                                               message:message
	                                                        preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
	__weak UIViewController *weakHost = host;
	[alert addAction:[UIAlertAction actionWithTitle:@"組み込んでリセット" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
		(void)action;
		UIViewController *strongHost = weakHost;
		if (strongHost) {
			run_hostdrv_setup(strongHost);
		}
	}]];
	[host presentViewController:alert animated:YES completion:nil];
}

// ---- testing

static UIViewController *top_controller(void)
{
	UIWindowScene *scene = (UIWindowScene *)UIApplication.sharedApplication.connectedScenes.allObjects.firstObject;
	UIViewController *top = scene.windows.firstObject.rootViewController;
	while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) {
		top = top.presentedViewController;
	}
	return top;
}

static UIViewController *top_disk_screen(void)
{
	UINavigationController *nav = s_list.navigationController;
	return nav.topViewController;
}

BOOL diskedit_debugcommand(NSString *command)
{
	if ([command isEqualToString:@"!diskedit"]) {
		diskedit_present(top_controller());
	}
	else if ([command hasPrefix:@"!disktap:"]) {
		NSString *title = [command substringFromIndex:9];
		UIViewController *top = top_disk_screen();
		if ([top isKindOfClass:[NP2DiskList class]]) {
			[(NP2DiskList *)top openDiskTitled:title];
		}
		else if ([top isKindOfClass:[UITableViewController class]]) {
			UITableView *table = ((UITableViewController *)top).tableView;
			for (NSInteger row = 0; row < [table numberOfRowsInSection:0]; row++) {
				NSIndexPath *path = [NSIndexPath indexPathForRow:row inSection:0];
				UITableViewCell *cell = [table.dataSource tableView:table cellForRowAtIndexPath:path];
				UIListContentConfiguration *content = (UIListContentConfiguration *)cell.contentConfiguration;
				if ([content.text isEqualToString:title] || [content.text hasPrefix:title]) {
					[table.delegate tableView:table didSelectRowAtIndexPath:path];
					break;
				}
			}
		}
	}
	else if ([command hasPrefix:@"!diskimport:"]) {
		UIViewController *top = top_disk_screen();
		if ([top isKindOfClass:[NP2DiskBrowser class]]) {
			[(NP2DiskBrowser *)top importURLs:@[ [NSURL fileURLWithPath:absolute_path([command substringFromIndex:12])] ]];
		}
	}
	else if ([command hasPrefix:@"!diskmkdir:"]) {
		UIViewController *top = top_disk_screen();
		if ([top isKindOfClass:[NP2DiskBrowser class]]) {
			[(NP2DiskBrowser *)top makeFolder:[command substringFromIndex:11]];
		}
	}
	else if ([command hasPrefix:@"!diskdelete:"]) {
		UIViewController *top = top_disk_screen();
		if ([top isKindOfClass:[NP2DiskBrowser class]]) {
			[(NP2DiskBrowser *)top deleteEntryNamed:[command substringFromIndex:12] confirm:NO];
		}
	}
	else if ([command isEqualToString:@"!diskdone"]) {
		[s_list done];
	}
	else if ([command isEqualToString:@"!hostdrvsetup"]) {
		if (hdds_in_use().count) {
			run_hostdrv_setup(top_controller());
		}
		else {
			diskedit_setuphostdrive(top_controller());
		}
	}
	else {
		return NO;
	}
	return YES;
}
