#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MTPDeviceDescriptor : NSObject

@property(nonatomic, readonly) uint32_t physicalLocationID;
@property(nonatomic, readonly) uint32_t busLocation;
@property(nonatomic, readonly) uint8_t deviceNumber;
@property(nonatomic, readonly) uint16_t vendorID;
@property(nonatomic, readonly) uint16_t productID;
@property(nonatomic, copy, readonly) NSString *usbSerialNumber;
@property(nonatomic, copy, readonly) NSString *displayName;
@property(nonatomic, copy, readonly) NSString *domainIdentifier;

- (instancetype)initWithPhysicalLocationID:(uint32_t)physicalLocationID
                               busLocation:(uint32_t)busLocation
                       deviceNumber:(uint8_t)deviceNumber
                            vendorID:(uint16_t)vendorID
                           productID:(uint16_t)productID
                     usbSerialNumber:(NSString *)usbSerialNumber
                        displayName:(NSString *)displayName;

@end

FOUNDATION_EXPORT NSArray<MTPDeviceDescriptor *> *MTPDetectDevices(NSError **error);
FOUNDATION_EXPORT BOOL MTPDomainDeviceIsPhysicallyConnected(NSString *domainIdentifier);
FOUNDATION_EXPORT BOOL MTPDomainIdentifierUsesStableIdentity(NSString *identifier);
FOUNDATION_EXPORT BOOL MTPParseDomainIdentifier(NSString *identifier,
                                                uint32_t *busLocation,
                                                uint8_t *deviceNumber,
                                                uint16_t *vendorID,
                                                uint16_t *productID);
FOUNDATION_EXPORT BOOL MTPResolveDomainIdentifier(NSString *identifier,
                                                  uint32_t *busLocation,
                                                  uint8_t *deviceNumber,
                                                  uint16_t *vendorID,
                                                  uint16_t *productID);

NS_ASSUME_NONNULL_END
