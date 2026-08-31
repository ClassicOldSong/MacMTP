#import "MTPDeviceMonitor.h"

#import <IOKit/IOKitLib.h>
#import <IOKit/usb/IOUSBHostFamilyDefinitions.h>

@interface MTPDeviceMonitor () {
  IONotificationPortRef _notificationPort;
  io_iterator_t _arrivalIterator;
  io_iterator_t _terminationIterator;
}
@property(nonatomic, copy) dispatch_block_t changeHandler;
@property(nonatomic, strong, nullable) dispatch_block_t pendingNotification;
- (void)scheduleChangeNotification;
@end

static void DrainUSBIterator(void *context, io_iterator_t iterator) {
  io_service_t service = IO_OBJECT_NULL;
  while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
    IOObjectRelease(service);
  }
  MTPDeviceMonitor *monitor = (__bridge MTPDeviceMonitor *)context;
  [monitor scheduleChangeNotification];
}

@implementation MTPDeviceMonitor

- (instancetype)initWithChangeHandler:(dispatch_block_t)changeHandler {
  self = [super init];
  if (self) {
    _changeHandler = [changeHandler copy];
  }
  return self;
}

- (void)dealloc {
  [self stop];
}

- (void)start {
  if (_notificationPort != nullptr) {
    return;
  }

  _notificationPort = IONotificationPortCreate(kIOMainPortDefault);
  if (_notificationPort == nullptr) {
    NSLog(@"Unable to create an IOKit notification port.");
    return;
  }

  CFRunLoopSourceRef source = IONotificationPortGetRunLoopSource(_notificationPort);
  CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);

  CFMutableDictionaryRef arrivalMatch = IOServiceMatching(kIOUSBHostDeviceClassName);
  kern_return_t arrivalResult = IOServiceAddMatchingNotification(
      _notificationPort,
      kIOFirstMatchNotification,
      arrivalMatch,
      DrainUSBIterator,
      (__bridge void *)self,
      &_arrivalIterator);

  CFMutableDictionaryRef terminationMatch = IOServiceMatching(kIOUSBHostDeviceClassName);
  kern_return_t terminationResult = IOServiceAddMatchingNotification(
      _notificationPort,
      kIOTerminatedNotification,
      terminationMatch,
      DrainUSBIterator,
      (__bridge void *)self,
      &_terminationIterator);

  if (arrivalResult != KERN_SUCCESS || terminationResult != KERN_SUCCESS) {
    NSLog(@"Unable to register USB notifications (%d, %d).",
          arrivalResult,
          terminationResult);
    [self stop];
    return;
  }

  DrainUSBIterator((__bridge void *)self, _arrivalIterator);
  DrainUSBIterator((__bridge void *)self, _terminationIterator);
}

- (void)stop {
  if (self.pendingNotification != nil) {
    dispatch_block_cancel(self.pendingNotification);
    self.pendingNotification = nil;
  }
  if (_arrivalIterator != IO_OBJECT_NULL) {
    IOObjectRelease(_arrivalIterator);
    _arrivalIterator = IO_OBJECT_NULL;
  }
  if (_terminationIterator != IO_OBJECT_NULL) {
    IOObjectRelease(_terminationIterator);
    _terminationIterator = IO_OBJECT_NULL;
  }
  if (_notificationPort != nullptr) {
    CFRunLoopSourceRef source = IONotificationPortGetRunLoopSource(_notificationPort);
    CFRunLoopRemoveSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
    IONotificationPortDestroy(_notificationPort);
    _notificationPort = nullptr;
  }
}

- (void)scheduleChangeNotification {
  if (self.pendingNotification != nil) {
    dispatch_block_cancel(self.pendingNotification);
  }
  __weak typeof(self) weakSelf = self;
  dispatch_block_t notification = dispatch_block_create(DISPATCH_BLOCK_INHERIT_QOS_CLASS, ^{
    typeof(self) self = weakSelf;
    self.pendingNotification = nil;
    if (self != nil) {
      self.changeHandler();
    }
  });
  self.pendingNotification = notification;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC),
                 dispatch_get_main_queue(),
                 notification);
}

@end
