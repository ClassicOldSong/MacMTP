#import "MTPDevice.h"

#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBHostFamilyDefinitions.h>

#include <libmtp.h>

static NSString *const MTPErrorDomain = @"com.sudomaker.MacMTP.libmtp";

static NSString *MTPString(const char *value) {
  if (value == nullptr || value[0] == '\0') {
    return @"";
  }
  NSString *string = [NSString stringWithUTF8String:value];
  if (string != nil) {
    return string;
  }
  return [[NSString alloc] initWithBytes:value
                                  length:strlen(value)
                                encoding:NSISOLatin1StringEncoding] ?: @"";
}

static NSString *MTPRegistryString(id value) {
  if (![value isKindOfClass:NSString.class]) {
    return @"";
  }
  return [(NSString *)value
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *MTPStableIdentityToken(NSString *serialNumber, uint32_t physicalLocationID) {
  NSString *serial = MTPRegistryString(serialNumber);
  if (serial.length > 0) {
    NSString *encoded =
        [serial stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet];
    if (encoded.length > 0) {
      return [@"s" stringByAppendingString:encoded];
    }
  }
  return [NSString stringWithFormat:@"l%08x", physicalLocationID];
}

static NSString *MTPStableIdentityTokenFromProperties(NSDictionary<NSString *, id> *properties) {
  return MTPStableIdentityToken(properties[@kUSBHostDevicePropertySerialNumberString],
                                [properties[@kUSBHostPropertyLocationID] unsignedIntValue]);
}

static NSDictionary<NSString *, id> *MTPRuntimeUSBProperties(NSString *stableIdentityToken,
                                                              uint32_t physicalLocationID,
                                                              uint32_t busLocation,
                                                              uint8_t deviceNumber,
                                                              uint16_t vendorID,
                                                              uint16_t productID) {
  io_iterator_t iterator = IO_OBJECT_NULL;
  kern_return_t result = IOServiceGetMatchingServices(
      kIOMainPortDefault,
      IOServiceMatching(kIOUSBHostDeviceClassName),
      &iterator);
  if (result != KERN_SUCCESS) {
    return @{};
  }

  NSDictionary<NSString *, id> *matchedProperties = @{};
  io_service_t service = IO_OBJECT_NULL;
  while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
    CFMutableDictionaryRef propertiesReference = nullptr;
    if (IORegistryEntryCreateCFProperties(service,
                                          &propertiesReference,
                                          kCFAllocatorDefault,
                                          0) != KERN_SUCCESS) {
      IOObjectRelease(service);
      continue;
    }

    NSMutableDictionary<NSString *, id> *properties =
        [(__bridge_transfer NSDictionary *)propertiesReference mutableCopy];
    uint32_t locationID = [properties[@kUSBHostPropertyLocationID] unsignedIntValue];
    uint32_t busNumber = locationID >> 24;
    BOOL locationMatches = stableIdentityToken.length > 0
                               ? [MTPStableIdentityTokenFromProperties(properties)
                                     isEqualToString:stableIdentityToken]
                               : (physicalLocationID != 0
                                      ? locationID == physicalLocationID
                                      : (busNumber == busLocation &&
                                         [properties[@kUSBHostDevicePropertyAddress] unsignedIntValue] ==
                                             deviceNumber));
    if (locationMatches &&
        [properties[@kUSBHostMatchingPropertyVendorID] unsignedIntValue] ==
            vendorID &&
        [properties[@kUSBHostMatchingPropertyProductID] unsignedIntValue] ==
            productID) {
      io_name_t registryName = {};
      if (IORegistryEntryGetName(service, registryName) == KERN_SUCCESS) {
        NSString *name = MTPString(registryName);
        if (name.length > 0 && ![name isEqualToString:@kIOUSBHostDeviceClassName]) {
          properties[@"MTPRegistryEntryName"] = name;
        }
      }
      matchedProperties = [properties copy];
      IOObjectRelease(service);
      break;
    }
    IOObjectRelease(service);
  }
  IOObjectRelease(iterator);
  return matchedProperties;
}

static BOOL ScanHex(NSString *value, unsigned long long maximum, unsigned long long *result) {
  NSScanner *scanner = [NSScanner scannerWithString:value];
  unsigned long long parsed = 0;
  if (![scanner scanHexLongLong:&parsed] || !scanner.isAtEnd || parsed > maximum) {
    return NO;
  }
  *result = parsed;
  return YES;
}

@implementation MTPDeviceDescriptor

- (instancetype)initWithPhysicalLocationID:(uint32_t)physicalLocationID
                               busLocation:(uint32_t)busLocation
                       deviceNumber:(uint8_t)deviceNumber
                            vendorID:(uint16_t)vendorID
                           productID:(uint16_t)productID
                     usbSerialNumber:(NSString *)usbSerialNumber
                        displayName:(NSString *)displayName {
  self = [super init];
  if (self) {
    _physicalLocationID = physicalLocationID;
    _busLocation = busLocation;
    _deviceNumber = deviceNumber;
    _vendorID = vendorID;
    _productID = productID;
    _usbSerialNumber = [usbSerialNumber copy];
    _displayName = [displayName copy];
    NSString *identityToken = MTPStableIdentityToken(usbSerialNumber, physicalLocationID);
    _domainIdentifier = [NSString stringWithFormat:@"mtp.v3.%04x.%04x.%@",
                                                   vendorID,
                                                   productID,
                                                   identityToken];
  }
  return self;
}

@end

NSArray<MTPDeviceDescriptor *> *MTPDetectDevices(NSError **error) {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    LIBMTP_Init();
  });

  LIBMTP_raw_device_t *rawDevices = nullptr;
  int count = 0;
  LIBMTP_error_number_t result = LIBMTP_Detect_Raw_Devices(&rawDevices, &count);
  if (result == LIBMTP_ERROR_NO_DEVICE_ATTACHED) {
    return @[];
  }
  if (result != LIBMTP_ERROR_NONE) {
    if (error != nullptr) {
      *error = [NSError errorWithDomain:MTPErrorDomain
                                   code:result
                               userInfo:@{NSLocalizedDescriptionKey : @"libmtp could not enumerate USB devices."}];
    }
    return @[];
  }

  NSMutableArray<MTPDeviceDescriptor *> *devices = [NSMutableArray arrayWithCapacity:(NSUInteger)count];
  for (int index = 0; index < count; ++index) {
    LIBMTP_raw_device_t raw = rawDevices[index];
    NSDictionary<NSString *, id> *runtime =
        MTPRuntimeUSBProperties(@"",
                                0,
                                raw.bus_location,
                                raw.devnum,
                                raw.device_entry.vendor_id,
                                raw.device_entry.product_id);
    // A raw USB address is reassigned during re-enumeration. Do not publish an
    // unstable identity or fallback name if IOKit cannot correlate this sample.
    if (runtime.count == 0) {
      continue;
    }
    uint32_t physicalLocationID = [runtime[@kUSBHostPropertyLocationID] unsignedIntValue];
    NSString *serialNumber = MTPRegistryString(runtime[@kUSBHostDevicePropertySerialNumberString]);
    if (serialNumber.length == 0 &&
        [runtime[@kUSBHostDevicePropertySerialNumberStringIndex] unsignedIntValue] != 0) {
      continue;
    }
    NSString *vendor = MTPRegistryString(runtime[@kUSBHostDevicePropertyVendorString]);
    if (vendor.length == 0) {
      vendor = MTPString(raw.device_entry.vendor);
    }
    NSString *product = MTPRegistryString(runtime[@kUSBHostDevicePropertyProductString]);
    if (product.length == 0) {
      product = MTPRegistryString(runtime[@"MTPRegistryEntryName"]);
    }
    if (product.length == 0) {
      product = MTPString(raw.device_entry.product);
    }

    NSString *displayName = product;
    if (vendor.length > 0 && product.length > 0 &&
        [product rangeOfString:vendor options:NSCaseInsensitiveSearch].location == NSNotFound) {
      displayName = [NSString stringWithFormat:@"%@ %@", vendor, product];
    } else if (displayName.length == 0) {
      displayName = vendor;
    }
    if (displayName.length == 0) {
      displayName = [NSString stringWithFormat:@"MTP Device %04x:%04x",
                                                raw.device_entry.vendor_id,
                                                raw.device_entry.product_id];
    }
    [devices addObject:[[MTPDeviceDescriptor alloc]
                           initWithPhysicalLocationID:physicalLocationID
                                  busLocation:raw.bus_location
                                  deviceNumber:raw.devnum
                                       vendorID:raw.device_entry.vendor_id
                                      productID:raw.device_entry.product_id
                                usbSerialNumber:serialNumber
                                   displayName:displayName]];
  }
  LIBMTP_FreeMemory(rawDevices);

  NSCountedSet<NSString *> *nameCounts = [[NSCountedSet alloc] init];
  for (MTPDeviceDescriptor *device in devices) {
    [nameCounts addObject:device.displayName];
  }
  for (NSUInteger index = 0; index < devices.count; ++index) {
    MTPDeviceDescriptor *device = devices[index];
    if ([nameCounts countForObject:device.displayName] > 1) {
      NSString *stableSuffix = device.usbSerialNumber.length > 0
                                   ? device.usbSerialNumber
                                   : [NSString stringWithFormat:@"Port %08x",
                                                                      device.physicalLocationID];
      NSString *uniqueName = [NSString stringWithFormat:@"%@ (%@)",
                                                       device.displayName,
                                                       stableSuffix];
      devices[index] = [[MTPDeviceDescriptor alloc]
          initWithPhysicalLocationID:device.physicalLocationID
                 busLocation:device.busLocation
                 deviceNumber:device.deviceNumber
                      vendorID:device.vendorID
                     productID:device.productID
               usbSerialNumber:device.usbSerialNumber
                  displayName:uniqueName];
    }
  }

  [devices sortUsingComparator:^NSComparisonResult(MTPDeviceDescriptor *left,
                                                    MTPDeviceDescriptor *right) {
    NSComparisonResult nameResult = [left.displayName localizedStandardCompare:right.displayName];
    if (nameResult != NSOrderedSame) {
      return nameResult;
    }
    return [left.domainIdentifier compare:right.domainIdentifier];
  }];
  return devices;
}

BOOL MTPDomainDeviceIsPhysicallyConnected(NSString *domainIdentifier) {
  uint32_t busLocation = 0;
  uint8_t deviceNumber = 0;
  uint16_t vendorID = 0;
  uint16_t productID = 0;
  return MTPResolveDomainIdentifier(domainIdentifier,
                                    &busLocation,
                                    &deviceNumber,
                                    &vendorID,
                                    &productID);
}

static BOOL MTPParseStableDomainIdentifier(NSString *identifier,
                                           NSString **stableIdentityToken,
                                           uint16_t *vendorID,
                                           uint16_t *productID) {
  NSArray<NSString *> *parts = [identifier componentsSeparatedByString:@"."];
  if (parts.count != 5 ||
      ![parts[0] isEqualToString:@"mtp"] ||
      ![parts[1] isEqualToString:@"v3"]) {
    return NO;
  }

  unsigned long long vendor = 0;
  unsigned long long product = 0;
  if (!ScanHex(parts[2], UINT16_MAX, &vendor) ||
      !ScanHex(parts[3], UINT16_MAX, &product)) {
    return NO;
  }

  NSString *identityToken = parts[4];
  BOOL validIdentity = NO;
  if ([identityToken hasPrefix:@"s"] && identityToken.length > 1) {
    NSString *encodedSerial = [identityToken substringFromIndex:1];
    NSString *serial = [encodedSerial stringByRemovingPercentEncoding];
    NSString *canonical = [serial
        stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet];
    validIdentity = serial.length > 0 && [canonical isEqualToString:encodedSerial];
  } else if ([identityToken hasPrefix:@"l"] && identityToken.length == 9) {
    unsigned long long location = 0;
    validIdentity = ScanHex([identityToken substringFromIndex:1], UINT32_MAX, &location) &&
                    location != 0;
  }
  if (!validIdentity) {
    return NO;
  }

  if (stableIdentityToken != nullptr) {
    *stableIdentityToken = identityToken;
  }
  if (vendorID != nullptr) {
    *vendorID = (uint16_t)vendor;
  }
  if (productID != nullptr) {
    *productID = (uint16_t)product;
  }
  return YES;
}

BOOL MTPDomainIdentifierUsesStableIdentity(NSString *identifier) {
  return MTPParseStableDomainIdentifier(identifier, nullptr, nullptr, nullptr);
}

static BOOL MTPParseLocationDomainIdentifier(NSString *identifier,
                                             uint32_t *physicalLocationID,
                                             uint16_t *vendorID,
                                             uint16_t *productID) {
  NSArray<NSString *> *parts = [identifier componentsSeparatedByString:@"."];
  if (parts.count != 5 ||
      ![parts[0] isEqualToString:@"mtp"] ||
      ![parts[1] isEqualToString:@"v2"]) {
    return NO;
  }

  unsigned long long location = 0;
  unsigned long long vendor = 0;
  unsigned long long product = 0;
  if (!ScanHex(parts[2], UINT32_MAX, &location) || location == 0 ||
      !ScanHex(parts[3], UINT16_MAX, &vendor) ||
      !ScanHex(parts[4], UINT16_MAX, &product)) {
    return NO;
  }

  if (physicalLocationID != nullptr) {
    *physicalLocationID = (uint32_t)location;
  }
  if (vendorID != nullptr) {
    *vendorID = (uint16_t)vendor;
  }
  if (productID != nullptr) {
    *productID = (uint16_t)product;
  }
  return YES;
}

BOOL MTPParseDomainIdentifier(NSString *identifier,
                              uint32_t *busLocation,
                              uint8_t *deviceNumber,
                              uint16_t *vendorID,
                              uint16_t *productID) {
  NSArray<NSString *> *parts = [identifier componentsSeparatedByString:@"."];
  if (parts.count != 5 || ![parts[0] isEqualToString:@"mtp"]) {
    return NO;
  }

  unsigned long long bus = 0;
  unsigned long long device = 0;
  unsigned long long vendor = 0;
  unsigned long long product = 0;
  if (!ScanHex(parts[1], UINT32_MAX, &bus) ||
      !ScanHex(parts[2], UINT8_MAX, &device) ||
      !ScanHex(parts[3], UINT16_MAX, &vendor) ||
      !ScanHex(parts[4], UINT16_MAX, &product)) {
    return NO;
  }

  if (busLocation != nullptr) {
    *busLocation = (uint32_t)bus;
  }
  if (deviceNumber != nullptr) {
    *deviceNumber = (uint8_t)device;
  }
  if (vendorID != nullptr) {
    *vendorID = (uint16_t)vendor;
  }
  if (productID != nullptr) {
    *productID = (uint16_t)product;
  }
  return YES;
}

BOOL MTPResolveDomainIdentifier(NSString *identifier,
                                uint32_t *busLocation,
                                uint8_t *deviceNumber,
                                uint16_t *vendorID,
                                uint16_t *productID) {
  uint32_t physicalLocationID = 0;
  uint32_t legacyBusLocation = 0;
  uint8_t legacyDeviceNumber = 0;
  uint16_t parsedVendorID = 0;
  uint16_t parsedProductID = 0;
  NSString *stableIdentityToken = nil;
  BOOL stable = MTPParseStableDomainIdentifier(identifier,
                                               &stableIdentityToken,
                                               &parsedVendorID,
                                               &parsedProductID);
  if (!stable) {
    BOOL locationBased = MTPParseLocationDomainIdentifier(identifier,
                                                          &physicalLocationID,
                                                          &parsedVendorID,
                                                          &parsedProductID);
    if (!locationBased &&
        !MTPParseDomainIdentifier(identifier,
                                  &legacyBusLocation,
                                  &legacyDeviceNumber,
                                  &parsedVendorID,
                                  &parsedProductID)) {
      return NO;
    }
  }

  NSDictionary<NSString *, id> *runtime =
      MTPRuntimeUSBProperties(stableIdentityToken ?: @"",
                              physicalLocationID,
                              legacyBusLocation,
                              legacyDeviceNumber,
                              parsedVendorID,
                              parsedProductID);
  if (runtime.count == 0) {
    return NO;
  }
  uint32_t locationID = [runtime[@kUSBHostPropertyLocationID] unsignedIntValue];
  if (busLocation != nullptr) {
    *busLocation = locationID >> 24;
  }
  if (deviceNumber != nullptr) {
    *deviceNumber =
        (uint8_t)[runtime[@kUSBHostDevicePropertyAddress] unsignedIntValue];
  }
  if (vendorID != nullptr) {
    *vendorID = parsedVendorID;
  }
  if (productID != nullptr) {
    *productID = parsedProductID;
  }
  return YES;
}
