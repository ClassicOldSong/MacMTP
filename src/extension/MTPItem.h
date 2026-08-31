#import <FileProvider/FileProvider.h>

#include <libmtp.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, MTPItemIdentifierKind) {
  MTPItemIdentifierKindInvalid,
  MTPItemIdentifierKindRoot,
  MTPItemIdentifierKindStorage,
  MTPItemIdentifierKindObject,
  MTPItemIdentifierKindWorkingSet,
};

@interface MTPItem : NSObject <NSFileProviderItem, NSFileProviderItemDecorating>

@property(nonatomic, readonly) BOOL folder;
@property(nonatomic, readonly) uint32_t storageID;
@property(nonatomic, readonly) uint32_t objectID;

+ (instancetype)rootItemWithName:(NSString *)name;
+ (instancetype)storageItemWithStorage:(const LIBMTP_devicestorage_t *)storage;
+ (instancetype)objectItemWithMetadata:(const LIBMTP_file_t *)metadata writable:(BOOL)writable;

@end


FOUNDATION_EXPORT NSFileProviderItemIdentifier MTPStorageItemIdentifier(uint32_t storageID);
FOUNDATION_EXPORT NSFileProviderItemIdentifier MTPObjectItemIdentifier(uint32_t storageID,
                                                                       uint32_t objectID);
FOUNDATION_EXPORT MTPItemIdentifierKind MTPParseItemIdentifier(NSFileProviderItemIdentifier identifier,
                                                               uint32_t *_Nullable storageID,
                                                               uint32_t *_Nullable objectID);

NS_ASSUME_NONNULL_END
