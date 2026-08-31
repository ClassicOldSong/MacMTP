#import "MTPConnection.h"

#import "MTPDevice.h"

#import <FileProvider/FileProvider.h>

@interface MTPConnection () {
  LIBMTP_mtpdevice_t *_device;
}
@property(nonatomic, copy) NSString *domainIdentifier;
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic) BOOL invalidated;
@end

static const void *MTPConnectionQueueKey = &MTPConnectionQueueKey;

@implementation MTPConnection

- (instancetype)initWithDomainIdentifier:(NSString *)domainIdentifier {
  self = [super init];
  if (self) {
    _domainIdentifier = [domainIdentifier copy];
    _queue = dispatch_queue_create("com.sudomaker.MacMTP.file-provider.device",
                                   DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_queue,
                                MTPConnectionQueueKey,
                                (void *)MTPConnectionQueueKey,
                                nullptr);
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      LIBMTP_Init();
    });
  }
  return self;
}

- (void)performWithDevice:(void (^)(LIBMTP_mtpdevice_t *, NSError *))operation {
  dispatch_async(self.queue, ^{
    if (self.invalidated) {
      operation(nullptr, MTPServerUnavailableError(@"The MTP provider is no longer active."));
      return;
    }

    NSError *error = nil;
    LIBMTP_mtpdevice_t *device = [self connectedDeviceWithError:&error];
    if (device != nullptr && LIBMTP_Get_Errorstack(device) != nullptr) {
      LIBMTP_Clear_Errorstack(device);
    }
    operation(device, error);
  });
}

- (LIBMTP_mtpdevice_t *)connectedDeviceWithError:(NSError **)error {
  if (_device != nullptr) {
    return _device;
  }

  uint32_t busLocation = 0;
  uint8_t deviceNumber = 0;
  uint16_t vendorID = 0;
  uint16_t productID = 0;
  if (!MTPResolveDomainIdentifier(self.domainIdentifier,
                                  &busLocation,
                                  &deviceNumber,
                                  &vendorID,
                                  &productID)) {
    if (error != nullptr) {
      *error = MTPServerUnavailableError(@"The MTP device is disconnected or unavailable.");
    }
    return nullptr;
  }

  LIBMTP_raw_device_t *rawDevices = nullptr;
  int count = 0;
  LIBMTP_error_number_t detectionResult = LIBMTP_Detect_Raw_Devices(&rawDevices, &count);
  if (detectionResult != LIBMTP_ERROR_NONE) {
    if (rawDevices != nullptr) {
      LIBMTP_FreeMemory(rawDevices);
    }
    if (error != nullptr) {
      *error = MTPServerUnavailableError(@"The MTP device is disconnected or unavailable.");
    }
    return nullptr;
  }

  for (int index = 0; index < count; ++index) {
    LIBMTP_raw_device_t *candidate = &rawDevices[index];
    if (candidate->bus_location == busLocation &&
        candidate->devnum == deviceNumber &&
        candidate->device_entry.vendor_id == vendorID &&
        candidate->device_entry.product_id == productID) {
      _device = LIBMTP_Open_Raw_Device_Uncached(candidate);
      break;
    }
  }
  LIBMTP_FreeMemory(rawDevices);

  if (_device == nullptr) {
    if (error != nullptr) {
      *error = MTPServerUnavailableError(@"The MTP device could not be opened. Unlock it and reconnect the USB cable.");
    }
    return nullptr;
  }

  if (LIBMTP_Get_Storage(_device, LIBMTP_STORAGE_SORTBY_NOTSORTED) != 0) {
    NSError *storageError = [self consumeDeviceErrorWithDescription:@"The device storage could not be read."
                                                              device:_device];
    LIBMTP_Release_Device(_device);
    _device = nullptr;
    if (error != nullptr) {
      *error = storageError;
    }
    return nullptr;
  }
  if (LIBMTP_Get_Errorstack(_device) != nullptr) {
    LIBMTP_Clear_Errorstack(_device);
  }
  return _device;
}

- (NSError *)consumeDeviceErrorWithDescription:(NSString *)description
                                         device:(LIBMTP_mtpdevice_t *)device {
  NSMutableArray<NSString *> *messages = [NSMutableArray array];
  for (LIBMTP_error_t *entry = LIBMTP_Get_Errorstack(device); entry != nullptr; entry = entry->next) {
    if (entry->error_text != nullptr) {
      NSString *message = [NSString stringWithUTF8String:entry->error_text];
      if (message.length > 0) {
        [messages addObject:message];
      }
    }
  }
  LIBMTP_Clear_Errorstack(device);
  NSString *details = messages.count > 0 ? [messages componentsJoinedByString:@" "] : @"libmtp reported an unknown error.";
  return MTPFileProviderOperationError([NSString stringWithFormat:@"%@ %@", description, details]);
}

- (void)invalidate {
  dispatch_block_t releaseDevice = ^{
    self.invalidated = YES;
    if (self->_device != nullptr) {
      LIBMTP_Release_Device(self->_device);
      self->_device = nullptr;
    }
  };
  if (dispatch_get_specific(MTPConnectionQueueKey) == MTPConnectionQueueKey) {
    releaseDevice();
  } else {
    dispatch_sync(self.queue, releaseDevice);
  }
}

- (void)dealloc {
  if (_device != nullptr) {
    LIBMTP_Release_Device(_device);
    _device = nullptr;
  }
}

@end


NSError *MTPServerUnavailableError(NSString *description) {
  return [NSError errorWithDomain:NSFileProviderErrorDomain
                             code:NSFileProviderErrorServerUnreachable
                         userInfo:@{NSLocalizedDescriptionKey : description}];
}

NSError *MTPFileProviderOperationError(NSString *description) {
  return [NSError errorWithDomain:NSCocoaErrorDomain
                             code:NSFileWriteUnknownError
                         userInfo:@{NSLocalizedDescriptionKey : description}];
}

NSError *MTPFileProviderPOSIXError(NSString *description, int errorNumber, BOOL writing) {
  NSError *underlying = [NSError errorWithDomain:NSPOSIXErrorDomain
                                             code:errorNumber
                                         userInfo:nil];
  return [NSError errorWithDomain:NSCocoaErrorDomain
                             code:(writing ? NSFileWriteUnknownError : NSFileReadUnknownError)
                         userInfo:@{
                           NSLocalizedDescriptionKey : description,
                           NSUnderlyingErrorKey : underlying,
                         }];
}
