#import <AppKit/AppKit.h>
#import "MTPDomainSyncState.h"

NS_ASSUME_NONNULL_BEGIN

// One cancellable request per domain. Dismissing releases the request, so a
// delayed File Provider acknowledgement cannot unmount it later.
@interface MTPUnmountController : NSObject <NSPopoverDelegate>
@property(nonatomic, readonly, strong) MTPDomainSyncState *syncState;
@property(nonatomic, readonly) BOOL waiting;
@property(nonatomic, copy, nullable) void (^completionHandler)(BOOL unmount);
- (instancetype)initWithSyncState:(MTPDomainSyncState *)syncState
                    statusButton:(nullable NSStatusBarButton *)statusButton;
- (void)start;
- (void)syncDidChange;
- (void)showPopover;
- (void)hidePopover;
- (void)waitForSync;
- (void)cancel;
- (void)forceUnmount;
@end

NS_ASSUME_NONNULL_END
