#import "MTPDevice.h"
#import "FileProviderExtension.h"
#import "MTPItem.h"
#import "MTPConnection.h"

#include <cstdio>
#include <cstdlib>

static void Check(bool condition, const char *message) {
  if (!condition) {
    std::fprintf(stderr, "Identifier test failed: %s\n", message);
    std::abort();
  }
}

// Only the USB connection is replaced. The provider must handle real storage
// metadata, missing storage, and forbidden container edits through its own code.
@interface StorageFixtureConnection : MTPConnection {
  LIBMTP_mtpdevice_t _fixtureDevice;
  LIBMTP_devicestorage_t _fixtureStorage;
}
@property(nonatomic, strong) NSError *connectionError;
@end

@implementation StorageFixtureConnection
- (instancetype)init {
  self = [super init];
  if (self) {
    static char name[] = "Internal Storage";
    _fixtureStorage.id = 0x00010001;
    _fixtureStorage.StorageDescription = name;
    _fixtureStorage.MaxCapacity = 1000000;
    _fixtureStorage.FreeSpaceInBytes = 500000;
    _fixtureDevice.storage = &_fixtureStorage;
  }
  return self;
}
- (void)performWithDevice:(void (^)(LIBMTP_mtpdevice_t *, NSError *))operation {
  operation(self.connectionError != nil ? nullptr : &_fixtureDevice, self.connectionError);
}
- (void)invalidate {}
@end

int main(void) {
  @autoreleasepool {
    MTPDeviceDescriptor *device = [[MTPDeviceDescriptor alloc]
        initWithPhysicalLocationID:0x1234abcd
               busLocation:0x12
               deviceNumber:0x42
                   vendorID:0x18d1
                  productID:0x4ee1
            usbSerialNumber:@"phone-123"
               displayName:@"Test Device"];
    Check([device.domainIdentifier isEqualToString:@"mtp.v3.18d1.4ee1.sphone%2D123"],
          "domain identifier formatting");

    MTPDeviceDescriptor *reenumeratedDevice = [[MTPDeviceDescriptor alloc]
        initWithPhysicalLocationID:0x55667788
               busLocation:0x55
              deviceNumber:0x77
                   vendorID:0x18d1
                  productID:0x4ee1
            usbSerialNumber:@"phone-123"
               displayName:@"Test Device"];
    Check([reenumeratedDevice.domainIdentifier isEqualToString:device.domainIdentifier],
          "domain identity survives USB address and port reassignment");
    Check(MTPDomainIdentifierUsesStableIdentity(device.domainIdentifier),
          "stable domain identifier recognition");
    Check(!MTPDomainIdentifierUsesStableIdentity(@"mtp.v3.18d1.4ee1.sbad%2Gserial"),
          "malformed serial encoding rejection");

    MTPDeviceDescriptor *portIdentifiedDevice = [[MTPDeviceDescriptor alloc]
        initWithPhysicalLocationID:0x1234abcd
               busLocation:0x12
              deviceNumber:0x42
                   vendorID:0x18d1
                  productID:0x4ee1
            usbSerialNumber:@""
               displayName:@"No Serial Device"];
    Check([portIdentifiedDevice.domainIdentifier
              isEqualToString:@"mtp.v3.18d1.4ee1.l1234abcd"],
          "physical port fallback identity");

    uint32_t bus = 0;
    uint8_t number = 0;
    uint16_t vendor = 0;
    uint16_t product = 0;
    Check(MTPParseDomainIdentifier(@"mtp.1234abcd.42.18d1.4ee1",
                                   &bus,
                                   &number,
                                   &vendor,
                                   &product),
          "valid legacy domain identifier parsing");
    Check(bus == 0x1234abcd, "bus parsing");
    Check(number == 0x42, "device number parsing");
    Check(vendor == 0x18d1, "vendor parsing");
    Check(product == 0x4ee1, "product parsing");
    Check(!MTPParseDomainIdentifier(@"mtp.1234abcd.42.18d1", &bus, &number, &vendor, &product),
          "short domain identifier rejection");
    Check(!MTPParseDomainIdentifier(@"mtp.1234abcd.142.18d1.4ee1", &bus, &number, &vendor, &product),
          "oversized device number rejection");
    Check(!MTPDomainDeviceIsPhysicallyConnected(@"not-a-domain"),
          "invalid physical device identifier rejection");

    uint32_t storageID = 0;
    uint32_t objectID = 0;
    Check(MTPParseItemIdentifier(@"storage.aabbccdd", &storageID, &objectID) ==
              MTPItemIdentifierKindStorage,
          "storage identifier parsing");
    Check(storageID == 0xaabbccdd, "storage ID value");
    Check(MTPParseItemIdentifier(@"object.aabbccdd.01020304", &storageID, &objectID) ==
              MTPItemIdentifierKindObject,
          "object identifier parsing");
    Check(storageID == 0xaabbccdd, "object storage ID value");
    Check(objectID == 0x01020304, "object ID value");
    Check(MTPParseItemIdentifier(@"object.aabbccdd.01020304.trailing", &storageID, &objectID) ==
              MTPItemIdentifierKindInvalid,
          "trailing item identifier component rejection");

    char filename[] = "photo.jpg";
    LIBMTP_file_t metadata = {};
    metadata.item_id = 0x01020304;
    metadata.parent_id = 0;
    metadata.storage_id = 0xaabbccdd;
    metadata.filename = filename;
    metadata.filesize = 12345;
    metadata.modificationdate = 1700000000;
    metadata.filetype = LIBMTP_FILETYPE_JPEG;
    MTPItem *item = [MTPItem objectItemWithMetadata:&metadata writable:YES];
    Check([item.itemIdentifier isEqualToString:@"object.aabbccdd.01020304"], "item identity");
    Check([item.parentItemIdentifier isEqualToString:@"storage.aabbccdd"], "item parent");
    Check([item.filename isEqualToString:@"photo.jpg"], "item filename");
    Check(!item.folder, "file classification");
    Check(item.contentPolicy == NSFileProviderContentPolicyInherited,
          "device files inherit the evictable content policy");
    Check([item.documentSize unsignedLongLongValue] == 12345, "item size");
    Check((item.capabilities & NSFileProviderItemCapabilitiesAllowsWriting) != 0,
          "writable item capability");

    NSFileProviderDomain *domain = [[NSFileProviderDomain alloc]
        initWithIdentifier:device.domainIdentifier
               displayName:device.displayName];
    id<NSFileProviderReplicatedExtension> provider =
        (id<NSFileProviderReplicatedExtension>)[[FileProviderExtension alloc] initWithDomain:domain];
    __block BOOL rootCallbackCalled = NO;
    [provider itemForIdentifier:NSFileProviderRootContainerItemIdentifier
                        request:[[NSFileProviderRequest alloc] init]
              completionHandler:^(id<NSFileProviderItem> root, NSError *error) {
      Check(error == nil, "root callback error");
      Check([root.filename isEqualToString:@"Test Device"], "root callback item");
      Check(root.contentPolicy == NSFileProviderContentPolicyDownloadLazily,
            "domain uses lazy, evictable caching");
      Check([root conformsToProtocol:@protocol(NSFileProviderItemDecorating)],
            "root decoration protocol");
      NSArray<NSFileProviderItemDecorationIdentifier> *decorations =
          [(id<NSFileProviderItemDecorating>)root decorations];
      Check(decorations.count == 1 &&
                [decorations.firstObject
                    isEqualToString:@"com.sudomaker.MacMTP.decoration.device"],
            "root folder badge");
      rootCallbackCalled = YES;
    }];
    Check(rootCallbackCalled, "synchronous root callback");

    NSError *trashError = nil;
    id<NSFileProviderEnumerator> trashEnumerator =
        [provider enumeratorForContainerItemIdentifier:NSFileProviderTrashContainerItemIdentifier
                                               request:[[NSFileProviderRequest alloc] init]
                                                 error:&trashError];
    Check(trashEnumerator == nil, "unsupported Trash enumerator");
    Check([trashError.domain isEqualToString:NSCocoaErrorDomain], "Trash error domain");
    Check(trashError.code == NSFeatureUnsupportedError, "Trash error code");
    [provider invalidate];

    FileProviderExtension *storageProvider = [[FileProviderExtension alloc] initWithDomain:domain];
    StorageFixtureConnection *connection = [[StorageFixtureConnection alloc] init];
    [storageProvider setValue:connection forKey:@"connection"];
    LIBMTP_devicestorage_t storage = {};
    char storageName[] = "Internal Storage";
    storage.id = 0x00010001;
    storage.StorageDescription = storageName;
    MTPItem *storageItem = [MTPItem storageItemWithStorage:&storage];
    Check(storageItem.contentPolicy == NSFileProviderContentPolicyInherited,
          "storage folders inherit the domain's cache policy");
    MTPItem *root = [MTPItem rootItemWithName:domain.displayName];
    NSFileProviderItemFields metadataFields = NSFileProviderItemContentModificationDate |
                                               NSFileProviderItemExtendedAttributes;
    for (MTPItem *container in @[storageItem, root]) {
      __block BOOL called = NO;
      [storageProvider modifyItem:container baseVersion:container.itemVersion
          changedFields:metadataFields contents:nil options:0 request:[[NSFileProviderRequest alloc] init]
          completionHandler:^(id<NSFileProviderItem> updated, NSFileProviderItemFields pending,
                              BOOL fetchContent, NSError *error) {
        Check(error == nil, "virtual container metadata is not a missing-item error");
        Check([updated.itemIdentifier isEqualToString:container.itemIdentifier],
              "metadata handling preserves the storage/root identity");
        Check(pending == metadataFields, "unsupported metadata fields are reported honestly");
        Check(!fetchContent, "virtual directory metadata does not fetch contents");
        called = YES;
      }];
      Check(called, "container metadata modification callback");
      for (NSNumber *field in @[@(NSFileProviderItemContents), @(NSFileProviderItemFilename),
                                @(NSFileProviderItemParentItemIdentifier)]) {
        called = NO;
        [storageProvider modifyItem:container baseVersion:container.itemVersion
            changedFields:field.unsignedLongLongValue contents:nil options:0
            request:[[NSFileProviderRequest alloc] init]
            completionHandler:^(id<NSFileProviderItem> updated, NSFileProviderItemFields pending,
                                BOOL fetchContent, NSError *error) {
          (void)pending;
          (void)fetchContent;
          Check(updated == nil && [error.domain isEqualToString:NSCocoaErrorDomain] &&
                    error.code == NSFileWriteNoPermissionError,
                "readonly virtual container edits are rejected rather than acknowledged");
          called = YES;
        }];
        Check(called, "readonly container edit callback");
      }
    }
    storage.id = 0x00020002;
    MTPItem *missingStorage = [MTPItem storageItemWithStorage:&storage];
    __block BOOL missingCalled = NO;
    [storageProvider modifyItem:missingStorage baseVersion:missingStorage.itemVersion
        changedFields:metadataFields contents:nil options:0 request:[[NSFileProviderRequest alloc] init]
        completionHandler:^(id<NSFileProviderItem> updated, NSFileProviderItemFields pending,
                            BOOL fetchContent, NSError *error) {
      (void)pending;
      (void)fetchContent;
      Check(updated == nil && [error.domain isEqualToString:NSFileProviderErrorDomain] &&
                error.code == NSFileProviderErrorNoSuchItem, "actually missing storage remains an error");
      missingCalled = YES;
    }];
    Check(missingCalled, "missing storage callback");
    connection.connectionError = MTPServerUnavailableError(@"Disconnected fixture");
    __block BOOL disconnectedCalled = NO;
    [storageProvider modifyItem:storageItem baseVersion:storageItem.itemVersion
        changedFields:metadataFields contents:nil options:0 request:[[NSFileProviderRequest alloc] init]
        completionHandler:^(id<NSFileProviderItem> updated, NSFileProviderItemFields pending,
                            BOOL fetchContent, NSError *error) {
      (void)pending;
      (void)fetchContent;
      Check(updated == nil && error.code == NSFileProviderErrorServerUnreachable,
            "disconnection is not swallowed as unsupported metadata");
      disconnectedCalled = YES;
    }];
    Check(disconnectedCalled, "disconnected storage callback");
    [storageProvider invalidate];
  }
  return 0;
}
