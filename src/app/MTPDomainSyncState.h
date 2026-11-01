#import <FileProvider/FileProvider.h>

NS_ASSUME_NONNULL_BEGIN

// File Provider owns the queue, including uploads that have not reached libmtp yet.
@interface MTPDomainSyncState : NSObject
@property(nonatomic, readonly, strong) NSFileProviderDomain *domain;
@property(nonatomic, readonly, strong) NSProgress *uploads;
@property(nonatomic, readonly, strong) NSProgress *downloads;
@property(nonatomic, readonly) BOOL busy;
@property(nonatomic, readonly) double fractionCompleted;
@property(nonatomic, copy, nullable) void (^changeHandler)(void);
- (nullable instancetype)initWithDomain:(NSFileProviderDomain *)domain;
- (void)waitForSync:(void (^)(NSError *_Nullable error))completion;
- (void)evictSyncedContents:(void (^)(NSError *_Nullable error))completion;
@end

NS_ASSUME_NONNULL_END
