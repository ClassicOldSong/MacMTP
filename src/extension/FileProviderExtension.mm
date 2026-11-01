#import "FileProviderExtension.h"

#import "MTPConnection.h"
#import "MTPEnumerator.h"
#import "MTPItem.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <unistd.h>

@interface FileProviderExtension () <MTPEnumerationSource>
@property(nonatomic, strong) NSFileProviderDomain *domain;
@property(nonatomic, strong) MTPConnection *connection;
@end

static NSError *NoSuchItemError(NSFileProviderItemIdentifier identifier) {
  return [NSError fileProviderErrorForNonExistentItemWithIdentifier:identifier];
}

static NSError *CancelledError(void) {
  return [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
}

static int TransferProgress(uint64_t sent, uint64_t total, const void *context) {
  NSProgress *progress = (__bridge NSProgress *)context;
  int64_t boundedTotal = total > INT64_MAX ? INT64_MAX : (int64_t)total;
  int64_t boundedSent = sent > INT64_MAX ? INT64_MAX : (int64_t)sent;
  // libmtp can report all bytes sent before the device's final response (and,
  // for replacements, cleanup). Reserve the final unit for operation success.
  progress.totalUnitCount = MAX((int64_t)1, boundedTotal);
  progress.completedUnitCount = MIN(boundedSent, progress.totalUnitCount - 1);
  return progress.cancelled ? 1 : 0;
}

static NSProgress *TransferProgressObject(NSProgressFileOperationKind kind) {
  NSProgress *progress = [NSProgress progressWithTotalUnitCount:-1];
  progress.kind = NSProgressKindFile;
  progress.fileOperationKind = kind;
  progress.cancellable = YES;
  progress.pausable = NO;
  return progress;
}

static void DestroyFileList(LIBMTP_file_t *files) {
  while (files != nullptr) {
    LIBMTP_file_t *next = files->next;
    files->next = nullptr;
    LIBMTP_destroy_file_t(files);
    files = next;
  }
}

static char *CopyUTF8String(NSString *string) {
  const char *value = string.UTF8String;
  return strdup(value != nullptr ? value : "Untitled");
}

@implementation FileProviderExtension

- (instancetype)initWithDomain:(NSFileProviderDomain *)domain {
  self = [super init];
  if (self) {
    _domain = domain;
    _connection = [[MTPConnection alloc] initWithDomainIdentifier:domain.identifier];
  }
  return self;
}

- (void)invalidate {
  [self.connection invalidate];
}

- (NSProgress *)itemForIdentifier:(NSFileProviderItemIdentifier)identifier
                          request:(NSFileProviderRequest *)request
                completionHandler:(void (^)(id<NSFileProviderItem>, NSError *))completionHandler {
  (void)request;
  NSProgress *progress = [NSProgress progressWithTotalUnitCount:1];
  if ([identifier isEqualToString:NSFileProviderRootContainerItemIdentifier]) {
    completionHandler([MTPItem rootItemWithName:self.domain.displayName], nil);
    progress.completedUnitCount = 1;
    return progress;
  }

  [self.connection performWithDevice:^(LIBMTP_mtpdevice_t *device, NSError *connectionError) {
    if (progress.cancelled) {
      completionHandler(nil, CancelledError());
      return;
    }
    if (connectionError != nil) {
      completionHandler(nil, connectionError);
      return;
    }
    NSError *error = nil;
    MTPItem *item = [self itemForIdentifier:identifier device:device error:&error];
    progress.completedUnitCount = 1;
    completionHandler(item, error);
  }];
  return progress;
}

- (NSProgress *)fetchContentsForItemWithIdentifier:(NSFileProviderItemIdentifier)itemIdentifier
                                           version:(NSFileProviderItemVersion *)requestedVersion
                                           request:(NSFileProviderRequest *)request
                                 completionHandler:(void (^)(NSURL *, id<NSFileProviderItem>, NSError *))completionHandler {
  (void)requestedVersion;
  (void)request;
  NSProgress *progress = TransferProgressObject(NSProgressFileOperationKindDownloading);
  [self.connection performWithDevice:^(LIBMTP_mtpdevice_t *device, NSError *connectionError) {
    if (progress.cancelled) {
      completionHandler(nil, nil, CancelledError());
      return;
    }
    if (connectionError != nil) {
      completionHandler(nil, nil, connectionError);
      return;
    }

    uint32_t storageID = 0;
    uint32_t objectID = 0;
    if (MTPParseItemIdentifier(itemIdentifier, &storageID, &objectID) != MTPItemIdentifierKindObject) {
      completionHandler(nil, nil, NoSuchItemError(itemIdentifier));
      return;
    }

    NSError *metadataError = nil;
    MTPItem *item = [self itemForIdentifier:itemIdentifier device:device error:&metadataError];
    if (item == nil || item.folder) {
      completionHandler(nil, nil, metadataError ?: NoSuchItemError(itemIdentifier));
      return;
    }

    NSFileProviderManager *manager = [NSFileProviderManager managerForDomain:self.domain];
    if (manager == nil) {
      completionHandler(nil,
                        nil,
                        MTPFileProviderOperationError(@"The File Provider domain is unavailable."));
      return;
    }
    NSError *temporaryError = nil;
    NSURL *temporaryDirectory = [manager temporaryDirectoryURLWithError:&temporaryError];
    if (temporaryDirectory == nil) {
      completionHandler(nil,
                        nil,
                        temporaryError ?: MTPFileProviderOperationError(@"A temporary File Provider directory is unavailable."));
      return;
    }
    NSString *temporaryName = [NSString stringWithFormat:@"%@-%@",
                                                         NSUUID.UUID.UUIDString,
                                                         item.filename];
    NSURL *temporaryURL = [temporaryDirectory URLByAppendingPathComponent:temporaryName isDirectory:NO];
    int descriptor = open(temporaryURL.fileSystemRepresentation, O_CREAT | O_EXCL | O_WRONLY, 0600);
    if (descriptor < 0) {
      completionHandler(nil,
                        nil,
                        MTPFileProviderPOSIXError(@"A temporary download file could not be created.",
                                                  errno,
                                                  YES));
      return;
    }

    int result = LIBMTP_Get_File_To_File_Descriptor(device,
                                                    objectID,
                                                    descriptor,
                                                    TransferProgress,
                                                    (__bridge const void *)progress);
    close(descriptor);
    if (result != 0) {
      unlink(temporaryURL.fileSystemRepresentation);
      NSError *error = progress.cancelled
                           ? CancelledError()
                           : [self.connection consumeDeviceErrorWithDescription:@"The file could not be downloaded."
                                                                         device:device];
      completionHandler(nil, nil, error);
      return;
    }
    progress.totalUnitCount = MAX((int64_t)1, item.documentSize.longLongValue);
    progress.completedUnitCount = progress.totalUnitCount;
    completionHandler(temporaryURL, item, nil);
  }];
  return progress;
}

- (NSProgress *)createItemBasedOnTemplate:(id<NSFileProviderItem>)itemTemplate
                                   fields:(NSFileProviderItemFields)fields
                                 contents:(NSURL *)url
                                  options:(NSFileProviderCreateItemOptions)options
                                  request:(NSFileProviderRequest *)request
                        completionHandler:(void (^)(id<NSFileProviderItem>,
                                                    NSFileProviderItemFields,
                                                    BOOL,
                                                    NSError *))completionHandler {
  (void)fields;
  (void)request;
  NSProgress *progress = TransferProgressObject(NSProgressFileOperationKindUploading);
  [self.connection performWithDevice:^(LIBMTP_mtpdevice_t *device, NSError *connectionError) {
    if (progress.cancelled) {
      completionHandler(nil, 0, NO, CancelledError());
      return;
    }
    if (connectionError != nil) {
      completionHandler(nil, 0, NO, connectionError);
      return;
    }

    uint32_t storageID = 0;
    uint32_t parentID = 0;
    NSError *parentError = nil;
    if (![self resolveParentIdentifier:itemTemplate.parentItemIdentifier
                                device:device
                             storageID:&storageID
                              parentID:&parentID
                                 error:&parentError]) {
      completionHandler(nil, 0, NO, parentError);
      return;
    }

    NSError *existingError = nil;
    MTPItem *existing = [self existingItemNamed:itemTemplate.filename
                                      storageID:storageID
                                        parentID:parentID
                                          device:device
                                           error:&existingError];
    if (existingError != nil) {
      completionHandler(nil, 0, NO, existingError);
      return;
    }
    if (existing != nil) {
      if ((options & NSFileProviderCreateItemMayAlreadyExist) != 0) {
        completionHandler(existing, 0, NO, nil);
      } else {
        completionHandler(nil, 0, NO, [NSError fileProviderErrorForCollisionWithItem:existing]);
      }
      return;
    }

    if ([itemTemplate.contentType conformsToType:UTTypeFolder]) {
      char *folderName = CopyUTF8String(itemTemplate.filename);
      uint32_t objectID = LIBMTP_Create_Folder(device, folderName, parentID, storageID);
      if (objectID == 0) {
        free(folderName);
        completionHandler(nil,
                          0,
                          NO,
                          [self.connection consumeDeviceErrorWithDescription:@"The folder could not be created."
                                                                        device:device]);
        return;
      }
      LIBMTP_file_t metadata = {};
      metadata.item_id = objectID;
      metadata.parent_id = parentID;
      metadata.storage_id = storageID;
      metadata.filename = folderName;
      metadata.filetype = LIBMTP_FILETYPE_FOLDER;
      MTPItem *created = [MTPItem objectItemWithMetadata:&metadata
                                                writable:[self storageIsWritable:storageID device:device]];
      free(folderName);
      progress.totalUnitCount = 1;
      progress.completedUnitCount = 1;
      [self signalWorkingSet];
      completionHandler(created, 0, NO, nil);
      return;
    }

    if (url == nil) {
      completionHandler(nil,
                        0,
                        NO,
                        MTPFileProviderOperationError(@"A new MTP file requires local contents."));
      return;
    }

    NSError *uploadError = nil;
    LIBMTP_file_t *uploaded = [self uploadContents:url
                                         filename:itemTemplate.filename
                                        storageID:storageID
                                          parentID:parentID
                                          progress:progress
                                            device:device
                                             error:&uploadError];
    if (uploaded == nullptr) {
      completionHandler(nil, 0, NO, uploadError);
      return;
    }
    MTPItem *created = [MTPItem objectItemWithMetadata:uploaded
                                              writable:[self storageIsWritable:storageID device:device]];
    LIBMTP_destroy_file_t(uploaded);
    [self signalWorkingSet];
    progress.completedUnitCount = progress.totalUnitCount;
    completionHandler(created, 0, NO, nil);
  }];
  return progress;
}

- (NSProgress *)modifyItem:(id<NSFileProviderItem>)item
                baseVersion:(NSFileProviderItemVersion *)version
              changedFields:(NSFileProviderItemFields)changedFields
                   contents:(NSURL *)newContents
                    options:(NSFileProviderModifyItemOptions)options
                    request:(NSFileProviderRequest *)request
          completionHandler:(void (^)(id<NSFileProviderItem>,
                                      NSFileProviderItemFields,
                                      BOOL,
                                      NSError *))completionHandler {
  (void)version;
  (void)options;
  (void)request;
  NSProgress *progress = TransferProgressObject(NSProgressFileOperationKindUploading);
  [self.connection performWithDevice:^(LIBMTP_mtpdevice_t *device, NSError *connectionError) {
    if (progress.cancelled) {
      completionHandler(nil, 0, NO, CancelledError());
      return;
    }
    if (connectionError != nil) {
      completionHandler(nil, 0, NO, connectionError);
      return;
    }

    uint32_t originalStorageID = 0;
    uint32_t objectID = 0;
    MTPItemIdentifierKind kind = MTPParseItemIdentifier(item.itemIdentifier, &originalStorageID, &objectID);
    if (kind == MTPItemIdentifierKindRoot || kind == MTPItemIdentifierKindStorage) {
      NSError *metadataError = nil;
      MTPItem *container = [self itemForIdentifier:item.itemIdentifier device:device error:&metadataError];
      if (container == nil) {
        completionHandler(nil, 0, NO, metadataError);
        return;
      }
      if ((changedFields & (NSFileProviderItemContents | NSFileProviderItemFilename |
                            NSFileProviderItemParentItemIdentifier)) != 0) {
        completionHandler(nil, 0, NO, [NSError errorWithDomain:NSCocoaErrorDomain
            code:NSFileWriteNoPermissionError userInfo:@{
              NSLocalizedDescriptionKey : @"The device and storage folders cannot be renamed, moved, or replaced."
            }]);
        return;
      }
      // These virtual directories are not MTP objects and cannot store Finder
      // timestamps, tags, or xattrs. On macOS 12+, returning the unchanged field
      // set declares unsupported metadata (NSFileProviderReplicatedExtension),
      // rather than claiming the storage is missing or the edit was uploaded.
      progress.totalUnitCount = 1;
      progress.completedUnitCount = 1;
      completionHandler(container, changedFields, NO, nil);
      return;
    }
    if (kind != MTPItemIdentifierKindObject) {
      completionHandler(nil, 0, NO, NoSuchItemError(item.itemIdentifier));
      return;
    }

    LIBMTP_Clear_Errorstack(device);
    LIBMTP_file_t *original = LIBMTP_Get_Filemetadata(device, objectID);
    if (original == nullptr) {
      NSError *metadataError = LIBMTP_Get_Errorstack(device) != nullptr
                                   ? [self.connection consumeDeviceErrorWithDescription:@"The item metadata could not be read before modification."
                                                                                 device:device]
                                   : NoSuchItemError(item.itemIdentifier);
      completionHandler(nil, 0, NO, metadataError);
      return;
    }
    if (original->storage_id == 0) {
      original->storage_id = originalStorageID;
    }

    uint32_t targetStorageID = original->storage_id;
    uint32_t targetParentID = original->parent_id;
    if (targetParentID == LIBMTP_FILES_AND_FOLDERS_ROOT) {
      targetParentID = 0;
    }
    if ((changedFields & NSFileProviderItemParentItemIdentifier) != 0) {
      NSError *parentError = nil;
      if (![self resolveParentIdentifier:item.parentItemIdentifier
                                  device:device
                               storageID:&targetStorageID
                                parentID:&targetParentID
                                   error:&parentError]) {
        LIBMTP_destroy_file_t(original);
        completionHandler(nil, 0, NO, parentError);
        return;
      }
    }

    NSString *originalName = original->filename != nullptr
                                 ? [NSString stringWithUTF8String:original->filename]
                                 : @"Untitled";
    NSString *targetName = (changedFields & NSFileProviderItemFilename) != 0
                               ? item.filename
                               : originalName;

    if ((changedFields & NSFileProviderItemContents) != 0) {
      if (newContents == nil || original->filetype == LIBMTP_FILETYPE_FOLDER) {
        LIBMTP_destroy_file_t(original);
        completionHandler(nil,
                          0,
                          NO,
                          MTPFileProviderOperationError(@"MTP content replacement requires a regular local file."));
        return;
      }

      NSString *backupName = [NSString stringWithFormat:@"%@.macmtp-backup-%@",
                                                        originalName,
                                                        NSUUID.UUID.UUIDString];
      char *backupBytes = CopyUTF8String(backupName);
      int backupResult = LIBMTP_Set_Object_Filename(device, objectID, backupBytes);
      free(backupBytes);
      if (backupResult != 0) {
        LIBMTP_destroy_file_t(original);
        completionHandler(nil,
                          0,
                          NO,
                          [self.connection consumeDeviceErrorWithDescription:@"The original file could not be prepared for replacement."
                                                                        device:device]);
        return;
      }

      NSError *uploadError = nil;
      LIBMTP_file_t *replacement = [self uploadContents:newContents
                                               filename:targetName
                                              storageID:targetStorageID
                                                parentID:targetParentID
                                                progress:progress
                                                  device:device
                                                   error:&uploadError];
      if (replacement == nullptr) {
        char *originalBytes = CopyUTF8String(originalName);
        LIBMTP_Set_Object_Filename(device, objectID, originalBytes);
        free(originalBytes);
        LIBMTP_destroy_file_t(original);
        completionHandler(nil, 0, NO, uploadError);
        return;
      }

      if (LIBMTP_Delete_Object(device, objectID) != 0) {
        LIBMTP_Delete_Object(device, replacement->item_id);
        char *originalBytes = CopyUTF8String(originalName);
        LIBMTP_Set_Object_Filename(device, objectID, originalBytes);
        free(originalBytes);
        LIBMTP_destroy_file_t(replacement);
        LIBMTP_destroy_file_t(original);
        completionHandler(nil,
                          0,
                          NO,
                          [self.connection consumeDeviceErrorWithDescription:@"The original file could not be replaced."
                                                                        device:device]);
        return;
      }

      MTPItem *result = [MTPItem objectItemWithMetadata:replacement
                                               writable:[self storageIsWritable:targetStorageID device:device]];
      LIBMTP_destroy_file_t(replacement);
      LIBMTP_destroy_file_t(original);
      [self signalWorkingSet];
      progress.completedUnitCount = progress.totalUnitCount;
      completionHandler(result, 0, NO, nil);
      return;
    }

    BOOL renamed = NO;
    if (![targetName isEqualToString:originalName]) {
      char *targetBytes = CopyUTF8String(targetName);
      int renameResult = LIBMTP_Set_Object_Filename(device, objectID, targetBytes);
      free(targetBytes);
      if (renameResult != 0) {
        LIBMTP_destroy_file_t(original);
        completionHandler(nil,
                          0,
                          NO,
                          [self.connection consumeDeviceErrorWithDescription:@"The item could not be renamed."
                                                                        device:device]);
        return;
      }
      renamed = YES;
    }

    uint32_t originalParentID = original->parent_id == LIBMTP_FILES_AND_FOLDERS_ROOT ? 0 : original->parent_id;
    if (targetStorageID != original->storage_id || targetParentID != originalParentID) {
      if (LIBMTP_Move_Object(device, objectID, targetStorageID, targetParentID) != 0) {
        if (renamed) {
          char *originalBytes = CopyUTF8String(originalName);
          LIBMTP_Set_Object_Filename(device, objectID, originalBytes);
          free(originalBytes);
        }
        LIBMTP_destroy_file_t(original);
        completionHandler(nil,
                          0,
                          NO,
                          [self.connection consumeDeviceErrorWithDescription:@"The item could not be moved."
                                                                        device:device]);
        return;
      }
    }
    LIBMTP_destroy_file_t(original);

    NSError *itemError = nil;
    MTPItem *updated = [self itemForIdentifier:MTPObjectItemIdentifier(targetStorageID, objectID)
                                       device:device
                                        error:&itemError];
    progress.totalUnitCount = 1;
    progress.completedUnitCount = 1;
    [self signalWorkingSet];
    completionHandler(updated, 0, NO, itemError);
  }];
  return progress;
}

- (NSProgress *)deleteItemWithIdentifier:(NSFileProviderItemIdentifier)identifier
                             baseVersion:(NSFileProviderItemVersion *)version
                                 options:(NSFileProviderDeleteItemOptions)options
                                 request:(NSFileProviderRequest *)request
                       completionHandler:(void (^)(NSError *))completionHandler {
  (void)version;
  (void)request;
  NSProgress *progress = [NSProgress progressWithTotalUnitCount:1];
  [self.connection performWithDevice:^(LIBMTP_mtpdevice_t *device, NSError *connectionError) {
    if (progress.cancelled) {
      completionHandler(CancelledError());
      return;
    }
    if (connectionError != nil) {
      completionHandler(connectionError);
      return;
    }

    uint32_t storageID = 0;
    uint32_t objectID = 0;
    if (MTPParseItemIdentifier(identifier, &storageID, &objectID) != MTPItemIdentifierKindObject) {
      completionHandler(NoSuchItemError(identifier));
      return;
    }

    LIBMTP_file_t *metadata = LIBMTP_Get_Filemetadata(device, objectID);
    if (metadata == nullptr) {
      if (LIBMTP_Get_Errorstack(device) != nullptr) {
        completionHandler([self.connection consumeDeviceErrorWithDescription:@"The item could not be checked before deletion."
                                                                       device:device]);
      } else {
        completionHandler(nil);
      }
      return;
    }
    BOOL folder = metadata->filetype == LIBMTP_FILETYPE_FOLDER;
    LIBMTP_destroy_file_t(metadata);

    if (folder && (options & NSFileProviderDeleteItemRecursive) == 0) {
      LIBMTP_Clear_Errorstack(device);
      LIBMTP_file_t *children = LIBMTP_Get_Files_And_Folders(device, storageID, objectID);
      if (children != nullptr) {
        DestroyFileList(children);
        completionHandler([NSError errorWithDomain:NSFileProviderErrorDomain
                                              code:NSFileProviderErrorDirectoryNotEmpty
                                          userInfo:nil]);
        return;
      }
      if (LIBMTP_Get_Errorstack(device) != nullptr) {
        completionHandler([self.connection consumeDeviceErrorWithDescription:@"The folder contents could not be checked."
                                                                       device:device]);
        return;
      }
    }

    if (LIBMTP_Delete_Object(device, objectID) != 0) {
      completionHandler([self.connection consumeDeviceErrorWithDescription:@"The item could not be deleted."
                                                                     device:device]);
      return;
    }
    progress.completedUnitCount = 1;
    [self signalWorkingSet];
    completionHandler(nil);
  }];
  return progress;
}

- (id<NSFileProviderEnumerator>)enumeratorForContainerItemIdentifier:(NSFileProviderItemIdentifier)containerItemIdentifier
                                                              request:(NSFileProviderRequest *)request
                                                                error:(NSError **)error {
  (void)request;
  if ([containerItemIdentifier isEqualToString:NSFileProviderTrashContainerItemIdentifier]) {
    if (error != nullptr) {
      *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                   code:NSFeatureUnsupportedError
                               userInfo:nil];
    }
    return nil;
  }
  MTPItemIdentifierKind kind = MTPParseItemIdentifier(containerItemIdentifier, nullptr, nullptr);
  if (kind == MTPItemIdentifierKindInvalid) {
    if (error != nullptr) {
      *error = NoSuchItemError(containerItemIdentifier);
    }
    return nil;
  }
  return [[MTPEnumerator alloc] initWithContainerIdentifier:containerItemIdentifier source:self];
}

- (void)loadItemsForContainer:(NSFileProviderItemIdentifier)containerIdentifier
                   completion:(void (^)(NSArray<id<NSFileProviderItem>> *, NSError *))completion {
  if ([containerIdentifier isEqualToString:NSFileProviderWorkingSetContainerItemIdentifier]) {
    completion(@[], nil);
    return;
  }

  [self.connection performWithDevice:^(LIBMTP_mtpdevice_t *device, NSError *connectionError) {
    if (connectionError != nil) {
      completion(nil, connectionError);
      return;
    }

    uint32_t storageID = 0;
    uint32_t objectID = 0;
    MTPItemIdentifierKind kind = MTPParseItemIdentifier(containerIdentifier, &storageID, &objectID);
    if (kind == MTPItemIdentifierKindRoot) {
      LIBMTP_Clear_Errorstack(device);
      if (LIBMTP_Get_Storage(device, LIBMTP_STORAGE_SORTBY_NOTSORTED) != 0) {
        completion(nil,
                   [self.connection consumeDeviceErrorWithDescription:@"The device storage list could not be refreshed."
                                                                 device:device]);
        return;
      }
      NSMutableArray<id<NSFileProviderItem>> *items = [NSMutableArray array];
      for (LIBMTP_devicestorage_t *storage = device->storage;
           storage != nullptr;
           storage = storage->next) {
        [items addObject:[MTPItem storageItemWithStorage:storage]];
      }
      completion(items, nil);
      return;
    }

    uint32_t parentID = kind == MTPItemIdentifierKindStorage
                            ? LIBMTP_FILES_AND_FOLDERS_ROOT
                            : objectID;
    if (kind != MTPItemIdentifierKindStorage && kind != MTPItemIdentifierKindObject) {
      completion(nil, NoSuchItemError(containerIdentifier));
      return;
    }

  LIBMTP_Clear_Errorstack(device);
  LIBMTP_file_t *files = LIBMTP_Get_Files_And_Folders(device, storageID, parentID);
    if (files == nullptr) {
      if (LIBMTP_Get_Errorstack(device) != nullptr) {
        completion(nil,
                   [self.connection consumeDeviceErrorWithDescription:@"The folder could not be enumerated."
                                                                 device:device]);
      } else {
        completion(@[], nil);
      }
      return;
    }

    BOOL writable = [self storageIsWritable:storageID device:device];
    NSMutableArray<id<NSFileProviderItem>> *items = [NSMutableArray array];
    for (LIBMTP_file_t *file = files; file != nullptr; file = file->next) {
      if (file->storage_id == 0) {
        file->storage_id = storageID;
      }
      [items addObject:[MTPItem objectItemWithMetadata:file writable:writable]];
    }
    DestroyFileList(files);
    completion(items, nil);
  }];
}

- (MTPItem *)itemForIdentifier:(NSFileProviderItemIdentifier)identifier
                        device:(LIBMTP_mtpdevice_t *)device
                         error:(NSError **)error {
  uint32_t storageID = 0;
  uint32_t objectID = 0;
  MTPItemIdentifierKind kind = MTPParseItemIdentifier(identifier, &storageID, &objectID);
  if (kind == MTPItemIdentifierKindRoot) {
    return [MTPItem rootItemWithName:self.domain.displayName];
  }
  if (kind == MTPItemIdentifierKindStorage) {
    LIBMTP_devicestorage_t *storage = [self storageForID:storageID device:device];
    if (storage != nullptr) {
      return [MTPItem storageItemWithStorage:storage];
    }
  } else if (kind == MTPItemIdentifierKindObject) {
    LIBMTP_Clear_Errorstack(device);
    LIBMTP_file_t *metadata = LIBMTP_Get_Filemetadata(device, objectID);
    if (metadata != nullptr) {
      if (metadata->storage_id == 0) {
        metadata->storage_id = storageID;
      }
      MTPItem *item = [MTPItem objectItemWithMetadata:metadata
                                             writable:[self storageIsWritable:storageID device:device]];
      LIBMTP_destroy_file_t(metadata);
      return item;
    }
    if (LIBMTP_Get_Errorstack(device) != nullptr) {
      if (error != nullptr) {
        *error = [self.connection consumeDeviceErrorWithDescription:@"The item metadata could not be read."
                                                              device:device];
      } else {
        LIBMTP_Clear_Errorstack(device);
      }
      return nil;
    }
  }

  if (error != nullptr) {
    *error = NoSuchItemError(identifier);
  }
  return nil;
}

- (BOOL)resolveParentIdentifier:(NSFileProviderItemIdentifier)identifier
                         device:(LIBMTP_mtpdevice_t *)device
                      storageID:(uint32_t *)storageID
                       parentID:(uint32_t *)parentID
                          error:(NSError **)error {
  uint32_t storage = 0;
  uint32_t object = 0;
  MTPItemIdentifierKind kind = MTPParseItemIdentifier(identifier, &storage, &object);
  if (kind == MTPItemIdentifierKindStorage) {
    if ([self storageForID:storage device:device] == nullptr) {
      if (error != nullptr) {
        *error = NoSuchItemError(identifier);
      }
      return NO;
    }
    *storageID = storage;
    *parentID = 0;
    return YES;
  }
  if (kind == MTPItemIdentifierKindObject) {
    LIBMTP_Clear_Errorstack(device);
    LIBMTP_file_t *metadata = LIBMTP_Get_Filemetadata(device, object);
    BOOL folder = metadata != nullptr && metadata->filetype == LIBMTP_FILETYPE_FOLDER;
    if (metadata != nullptr) {
      LIBMTP_destroy_file_t(metadata);
    }
    if (!folder) {
      if (error != nullptr) {
        if (LIBMTP_Get_Errorstack(device) != nullptr) {
          *error = [self.connection consumeDeviceErrorWithDescription:@"The destination folder metadata could not be read."
                                                                device:device];
        } else {
          *error = NoSuchItemError(identifier);
        }
      } else if (LIBMTP_Get_Errorstack(device) != nullptr) {
        LIBMTP_Clear_Errorstack(device);
      }
      return NO;
    }
    *storageID = storage;
    *parentID = object;
    return YES;
  }
  if (error != nullptr) {
    *error = MTPFileProviderOperationError(@"Items must be created inside an MTP storage or folder.");
  }
  return NO;
}

- (MTPItem *)existingItemNamed:(NSString *)filename
                     storageID:(uint32_t)storageID
                       parentID:(uint32_t)parentID
                         device:(LIBMTP_mtpdevice_t *)device
                          error:(NSError **)error {
  uint32_t listingParent = parentID == 0 ? LIBMTP_FILES_AND_FOLDERS_ROOT : parentID;
  LIBMTP_Clear_Errorstack(device);
  LIBMTP_file_t *files = LIBMTP_Get_Files_And_Folders(device, storageID, listingParent);
  BOOL listingFailed = files == nullptr && LIBMTP_Get_Errorstack(device) != nullptr;
  MTPItem *match = nil;
  BOOL writable = [self storageIsWritable:storageID device:device];
  for (LIBMTP_file_t *file = files; file != nullptr; file = file->next) {
    NSString *candidate = file->filename != nullptr ? [NSString stringWithUTF8String:file->filename] : @"";
    if ([candidate isEqualToString:filename]) {
      if (file->storage_id == 0) {
        file->storage_id = storageID;
      }
      match = [MTPItem objectItemWithMetadata:file writable:writable];
      break;
    }
  }
  DestroyFileList(files);
  if (listingFailed) {
    if (error != nullptr) {
      *error = [self.connection consumeDeviceErrorWithDescription:@"The destination folder could not be checked."
                                                            device:device];
    } else {
      LIBMTP_Clear_Errorstack(device);
    }
    return nil;
  }
  if (LIBMTP_Get_Errorstack(device) != nullptr) {
    LIBMTP_Clear_Errorstack(device);
  }
  return match;
}

- (LIBMTP_file_t *)uploadContents:(NSURL *)url
                         filename:(NSString *)filename
                        storageID:(uint32_t)storageID
                          parentID:(uint32_t)parentID
                          progress:(NSProgress *)progress
                            device:(LIBMTP_mtpdevice_t *)device
                             error:(NSError **)error {
  int descriptor = open(url.fileSystemRepresentation, O_RDONLY);
  if (descriptor < 0) {
    if (error != nullptr) {
      *error = MTPFileProviderPOSIXError(@"The local upload file could not be opened.",
                                         errno,
                                         NO);
    }
    return nullptr;
  }

  struct stat status = {};
  if (fstat(descriptor, &status) != 0) {
    int savedErrno = errno;
    close(descriptor);
    if (error != nullptr) {
      *error = MTPFileProviderPOSIXError(@"The local upload file metadata could not be read.",
                                         savedErrno,
                                         NO);
    }
    return nullptr;
  }

  LIBMTP_file_t *metadata = LIBMTP_new_file_t();
  metadata->filename = CopyUTF8String(filename);
  metadata->filesize = (uint64_t)status.st_size;
  metadata->filetype = LIBMTP_FILETYPE_UNKNOWN;
  metadata->parent_id = parentID;
  metadata->storage_id = storageID;
  metadata->modificationdate = status.st_mtime;

  progress.totalUnitCount = MAX((int64_t)1, status.st_size);

  int result = LIBMTP_Send_File_From_File_Descriptor(device,
                                                     descriptor,
                                                     metadata,
                                                     TransferProgress,
                                                     (__bridge const void *)progress);
  close(descriptor);
  if (result != 0) {
    if (error != nullptr) {
      *error = progress.cancelled
                   ? CancelledError()
                   : [self.connection consumeDeviceErrorWithDescription:@"The file could not be uploaded."
                                                                 device:device];
    }
    LIBMTP_destroy_file_t(metadata);
    return nullptr;
  }
  return metadata;
}

- (LIBMTP_devicestorage_t *)storageForID:(uint32_t)storageID
                                  device:(LIBMTP_mtpdevice_t *)device {
  for (LIBMTP_devicestorage_t *storage = device->storage;
       storage != nullptr;
       storage = storage->next) {
    if (storage->id == storageID) {
      return storage;
    }
  }
  return nullptr;
}

- (BOOL)storageIsWritable:(uint32_t)storageID device:(LIBMTP_mtpdevice_t *)device {
  LIBMTP_devicestorage_t *storage = [self storageForID:storageID device:device];
  return storage != nullptr && storage->AccessCapability == 0;
}

- (void)signalWorkingSet {
  NSFileProviderManager *manager = [NSFileProviderManager managerForDomain:self.domain];
  [manager signalEnumeratorForContainerItemIdentifier:NSFileProviderWorkingSetContainerItemIdentifier
                                    completionHandler:^(NSError *error) {
    if (error != nil) {
      NSLog(@"Could not signal the MTP working set: %@", error);
    }
  }];
}

@end
