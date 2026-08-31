#import <FileProvider/FileProvider.h>

NS_ASSUME_NONNULL_BEGIN

@protocol MTPEnumerationSource <NSObject>
- (void)loadItemsForContainer:(NSFileProviderItemIdentifier)containerIdentifier
                   completion:(void (^)(NSArray<id<NSFileProviderItem>> *_Nullable items,
                                        NSError *_Nullable error))completion;
@end

@interface MTPEnumerator : NSObject <NSFileProviderEnumerator>
- (instancetype)initWithContainerIdentifier:(NSFileProviderItemIdentifier)containerIdentifier
                                      source:(id<MTPEnumerationSource>)source;
@end

NS_ASSUME_NONNULL_END

