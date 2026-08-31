#import <Foundation/Foundation.h>

#include <libmtp.h>

NS_ASSUME_NONNULL_BEGIN

@interface MTPConnection : NSObject

- (instancetype)initWithDomainIdentifier:(NSString *)domainIdentifier;
- (void)performWithDevice:(void (^)(LIBMTP_mtpdevice_t *_Nullable device,
                                    NSError *_Nullable connectionError))operation;
- (NSError *)consumeDeviceErrorWithDescription:(NSString *)description
                                         device:(LIBMTP_mtpdevice_t *)device;
- (void)invalidate;

@end


FOUNDATION_EXPORT NSError *MTPServerUnavailableError(NSString *description);
FOUNDATION_EXPORT NSError *MTPFileProviderOperationError(NSString *description);
FOUNDATION_EXPORT NSError *MTPFileProviderPOSIXError(NSString *description,
                                                     int errorNumber,
                                                     BOOL writing);

NS_ASSUME_NONNULL_END
