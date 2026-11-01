#import "MTPItem.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface MTPItem ()
@property(nonatomic, copy) NSFileProviderItemIdentifier itemIdentifier;
@property(nonatomic, copy) NSFileProviderItemIdentifier parentItemIdentifier;
@property(nonatomic, copy) NSString *filename;
@property(nonatomic, copy) UTType *contentType;
@property(nonatomic) NSFileProviderItemCapabilities capabilities;
@property(nonatomic, copy, nullable) NSNumber *documentSize;
@property(nonatomic, copy, nullable) NSDate *contentModificationDate;
@property(nonatomic, strong) NSFileProviderItemVersion *itemVersion;
@property(nonatomic, strong, nullable) NSArray<NSFileProviderItemDecorationIdentifier> *decorations;
@property(nonatomic) BOOL folder;
@property(nonatomic) uint32_t storageID;
@property(nonatomic) uint32_t objectID;
@end

static NSFileProviderItemDecorationIdentifier const MTPRootDecorationIdentifier =
    @"com.sudomaker.MacMTP.decoration.device";

static NSString *MTPString(const char *value, NSString *fallback) {
  if (value == nullptr || value[0] == '\0') {
    return fallback;
  }
  NSString *string = [NSString stringWithUTF8String:value];
  if (string != nil) {
    return string;
  }
  return [[NSString alloc] initWithBytes:value
                                  length:strlen(value)
                                encoding:NSISOLatin1StringEncoding] ?: fallback;
}

static NSData *VersionData(NSString *value) {
  return [value dataUsingEncoding:NSUTF8StringEncoding];
}

static BOOL ScanHex(NSString *value, uint32_t *result) {
  NSScanner *scanner = [NSScanner scannerWithString:value];
  unsigned long long parsed = 0;
  if (![scanner scanHexLongLong:&parsed] || !scanner.isAtEnd || parsed > UINT32_MAX) {
    return NO;
  }
  *result = (uint32_t)parsed;
  return YES;
}

@implementation MTPItem

- (NSFileProviderContentPolicy)contentPolicy {
  // These items describe storage on the device. Clean local contents are a
  // cache, not permanently pinned copies. Explicitly use the macOS 13+ policy
  // API: the legacy capability fallback otherwise marks them non-evictable.
  return [self.itemIdentifier isEqualToString:NSFileProviderRootContainerItemIdentifier]
             ? NSFileProviderContentPolicyDownloadLazily
             : NSFileProviderContentPolicyInherited;
}

+ (instancetype)rootItemWithName:(NSString *)name {
  MTPItem *item = [[self alloc] init];
  item.itemIdentifier = NSFileProviderRootContainerItemIdentifier;
  item.parentItemIdentifier = NSFileProviderRootContainerItemIdentifier;
  item.filename = name.length > 0 ? name : @"MTP Device";
  item.contentType = UTTypeFolder;
  item.capabilities = NSFileProviderItemCapabilitiesAllowsReading;
  item.decorations = @[MTPRootDecorationIdentifier];
  item.folder = YES;
  item.itemVersion = [[NSFileProviderItemVersion alloc]
      initWithContentVersion:VersionData(@"root")
             metadataVersion:VersionData(
                 [item.filename stringByAppendingFormat:@":%@:policy=%ld", MTPRootDecorationIdentifier,
                                                       (long)item.contentPolicy])];
  return item;
}

+ (instancetype)storageItemWithStorage:(const LIBMTP_devicestorage_t *)storage {
  MTPItem *item = [[self alloc] init];
  item.storageID = storage->id;
  item.itemIdentifier = MTPStorageItemIdentifier(storage->id);
  item.parentItemIdentifier = NSFileProviderRootContainerItemIdentifier;
  NSString *fallback = [NSString stringWithFormat:@"Storage %08x", storage->id];
  item.filename = MTPString(storage->StorageDescription, fallback);
  item.contentType = UTTypeFolder;
  item.folder = YES;
  item.capabilities = NSFileProviderItemCapabilitiesAllowsReading;
  if (storage->AccessCapability == 0) {
    item.capabilities |= NSFileProviderItemCapabilitiesAllowsAddingSubItems;
  }
  NSString *version = [NSString stringWithFormat:@"%08x:%llu:%llu",
                                                 storage->id,
                                                 storage->MaxCapacity,
                                                 storage->FreeSpaceInBytes];
  item.itemVersion = [[NSFileProviderItemVersion alloc]
      initWithContentVersion:VersionData(version)
             metadataVersion:VersionData([version stringByAppendingFormat:@":%@:policy=%ld", item.filename,
                                                                         (long)item.contentPolicy])];
  return item;
}

+ (instancetype)objectItemWithMetadata:(const LIBMTP_file_t *)metadata writable:(BOOL)writable {
  MTPItem *item = [[self alloc] init];
  item.storageID = metadata->storage_id;
  item.objectID = metadata->item_id;
  item.itemIdentifier = MTPObjectItemIdentifier(metadata->storage_id, metadata->item_id);
  if (metadata->parent_id == 0 || metadata->parent_id == LIBMTP_FILES_AND_FOLDERS_ROOT) {
    item.parentItemIdentifier = MTPStorageItemIdentifier(metadata->storage_id);
  } else {
    item.parentItemIdentifier = MTPObjectItemIdentifier(metadata->storage_id, metadata->parent_id);
  }
  item.filename = MTPString(metadata->filename, [NSString stringWithFormat:@"Object %u", metadata->item_id]);
  item.folder = metadata->filetype == LIBMTP_FILETYPE_FOLDER;
  if (item.folder) {
    item.contentType = UTTypeFolder;
  } else {
    UTType *type = nil;
    if (item.filename.pathExtension.length > 0) {
      type = [UTType typeWithFilenameExtension:item.filename.pathExtension];
    }
    item.contentType = type ?: UTTypeData;
    item.documentSize = @(metadata->filesize);
  }

  item.capabilities = NSFileProviderItemCapabilitiesAllowsReading;
  if (writable) {
    item.capabilities |= NSFileProviderItemCapabilitiesAllowsRenaming |
                         NSFileProviderItemCapabilitiesAllowsReparenting |
                         NSFileProviderItemCapabilitiesAllowsDeleting;
    if (item.folder) {
      item.capabilities |= NSFileProviderItemCapabilitiesAllowsAddingSubItems;
    } else {
      item.capabilities |= NSFileProviderItemCapabilitiesAllowsWriting;
    }
  }

  if (metadata->modificationdate > 0) {
    item.contentModificationDate = [NSDate dateWithTimeIntervalSince1970:metadata->modificationdate];
  }
  NSString *contentVersion = [NSString stringWithFormat:@"%08x:%08x:%llu:%lld",
                                                        metadata->storage_id,
                                                        metadata->item_id,
                                                        metadata->filesize,
                                                        (long long)metadata->modificationdate];
  NSString *metadataVersion = [NSString stringWithFormat:@"%@:%08x:%@:%lld:policy=%ld",
                                                         contentVersion,
                                                         metadata->parent_id,
                                                         item.filename,
                                                         (long long)metadata->modificationdate,
                                                         (long)item.contentPolicy];
  item.itemVersion = [[NSFileProviderItemVersion alloc]
      initWithContentVersion:VersionData(contentVersion)
             metadataVersion:VersionData(metadataVersion)];
  return item;
}

@end

NSFileProviderItemIdentifier MTPStorageItemIdentifier(uint32_t storageID) {
  return [NSString stringWithFormat:@"storage.%08x", storageID];
}

NSFileProviderItemIdentifier MTPObjectItemIdentifier(uint32_t storageID, uint32_t objectID) {
  return [NSString stringWithFormat:@"object.%08x.%08x", storageID, objectID];
}

MTPItemIdentifierKind MTPParseItemIdentifier(NSFileProviderItemIdentifier identifier,
                                              uint32_t *storageID,
                                              uint32_t *objectID) {
  if ([identifier isEqualToString:NSFileProviderRootContainerItemIdentifier]) {
    return MTPItemIdentifierKindRoot;
  }
  if ([identifier isEqualToString:NSFileProviderWorkingSetContainerItemIdentifier]) {
    return MTPItemIdentifierKindWorkingSet;
  }

  NSArray<NSString *> *parts = [identifier componentsSeparatedByString:@"."];
  uint32_t storage = 0;
  uint32_t object = 0;
  if (parts.count == 2 && [parts[0] isEqualToString:@"storage"] && ScanHex(parts[1], &storage)) {
    if (storageID != nullptr) {
      *storageID = storage;
    }
    return MTPItemIdentifierKindStorage;
  }
  if (parts.count == 3 && [parts[0] isEqualToString:@"object"] &&
      ScanHex(parts[1], &storage) && ScanHex(parts[2], &object)) {
    if (storageID != nullptr) {
      *storageID = storage;
    }
    if (objectID != nullptr) {
      *objectID = object;
    }
    return MTPItemIdentifierKindObject;
  }
  return MTPItemIdentifierKindInvalid;
}
