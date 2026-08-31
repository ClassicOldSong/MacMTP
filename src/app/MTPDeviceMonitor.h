#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MTPDeviceMonitor : NSObject

- (instancetype)initWithChangeHandler:(dispatch_block_t)changeHandler;
- (void)start;
- (void)stop;

@end

NS_ASSUME_NONNULL_END

