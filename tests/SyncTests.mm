#import "MTPDomainSyncState.h"
#import "MTPUnmountController.h"

#include <cstdio>
#include <cstdlib>

static void Check(BOOL condition, const char *message) {
  if (!condition) {
    std::fprintf(stderr, "Sync test failed: %s\n", message);
    std::abort();
  }
}

// Substitute only the system-owned progress source, sync barrier, and eviction;
// all unmount decisions and progress calculations use production code.
@interface TestSyncState : MTPDomainSyncState
@property(nonatomic, strong) NSFileProviderDomain *domain;
@property(nonatomic, strong) NSProgress *uploads;
@property(nonatomic, strong) NSProgress *downloads;
@property(nonatomic, copy) void (^acknowledgement)(NSError *);
@property(nonatomic, copy) void (^evictionCompletion)(NSError *);
@property(nonatomic) NSUInteger waitCount;
@property(nonatomic) NSUInteger evictionCount;
@property(nonatomic) BOOL delayEviction;
@end

@implementation TestSyncState
@synthesize domain = _testDomain, uploads = _testUploads, downloads = _testDownloads;
- (instancetype)init {
  self = [super init];
  if (self) {
    self.domain = [[NSFileProviderDomain alloc] initWithIdentifier:NSUUID.UUID.UUIDString
                                                    displayName:@"OnePlus 13"];
    self.uploads = [NSProgress discreteProgressWithTotalUnitCount:1000];
    self.uploads.completedUnitCount = 250;
    self.downloads = [NSProgress discreteProgressWithTotalUnitCount:1];
    self.downloads.completedUnitCount = 1;
  }
  return self;
}
- (void)waitForSync:(void (^)(NSError *))completion {
  self.waitCount += 1;
  self.acknowledgement = completion;
}
- (void)evictSyncedContents:(void (^)(NSError *))completion {
  self.evictionCount += 1;
  if (self.delayEviction) {
    self.evictionCompletion = completion;
  } else {
    completion(nil);
  }
}
@end

@interface HeadlessUnmount : MTPUnmountController
@end
@implementation HeadlessUnmount
- (void)showPopover {} // Exercise decisions without opening windows in ctest.
@end

static HeadlessUnmount *Request(TestSyncState *state, NSMutableArray<NSNumber *> *results) {
  HeadlessUnmount *request = [[HeadlessUnmount alloc] initWithSyncState:state statusButton:nil];
  request.completionHandler = ^(BOOL unmount) { [results addObject:@(unmount)]; };
  return request;
}

static void TestProgress(void) {
  TestSyncState *state = [[TestSyncState alloc] init];
  Check(state.busy && state.fractionCompleted == 0.25, "upload byte progress");
  state.downloads.totalUnitCount = 1000;
  state.downloads.completedUnitCount = 750;
  Check(state.fractionCompleted == 0.5, "uploads and downloads combined by bytes");
  state.uploads.totalUnitCount = -1;
  Check(state.fractionCompleted == -1, "unknown size stays indeterminate");
  state.uploads.totalUnitCount = 1000;
  state.uploads.completedUnitCount = 1000;
  Check(state.busy, "download still in flight after upload finishes");
  state.downloads.completedUnitCount = 1000;
  Check(!state.busy && state.fractionCompleted == 1, "idle progress");
}

static void TestWaitAndDismiss(void) {
  TestSyncState *state = [[TestSyncState alloc] init];
  NSMutableArray *results = [NSMutableArray array];
  HeadlessUnmount *request = Request(state, results);
  [request waitForSync];
  [request waitForSync];
  Check(state.waitCount == 0 && request.waiting, "wait for transfers before asking for final acknowledgement");
  state.uploads.completedUnitCount = 1000;
  [request syncDidChange];
  Check(state.waitCount == 1 && results.count == 0,
        "100 percent starts a final barrier without bypassing pending on-disk changes");
  state.acknowledgement(nil);
  Check(results.count == 1 && [results[0] boolValue], "unmount after acknowledgement and idle");
  [request syncDidChange];
  [request forceUnmount];
  Check(results.count == 1, "unmount exactly once");

  state = [[TestSyncState alloc] init];
  state.uploads.completedUnitCount = 1000;
  results = [NSMutableArray array];
  request = Request(state, results);
  [request waitForSync];
  [request cancel];
  state.acknowledgement(nil);
  [request syncDidChange];
  Check(results.count == 1 && ![results[0] boolValue], "dismiss prevents delayed auto-unmount");
  Check(state.evictionCount == 0, "dismiss before acknowledgement prevents cache eviction");
  Check(!request.waiting, "dismiss clears wait state");

  state = [[TestSyncState alloc] init];
  results = [NSMutableArray array];
  request = Request(state, results);
  [request waitForSync];
  [request cancel];
  state.uploads.completedUnitCount = 1000;
  [request syncDidChange];
  Check(state.waitCount == 0 && results.count == 1 && ![results[0] boolValue],
        "dismiss during upload prevents starting a later barrier");
}

static void TestDownloadsAndErrors(void) {
  TestSyncState *state = [[TestSyncState alloc] init];
  NSMutableArray *results = [NSMutableArray array];
  HeadlessUnmount *request = Request(state, results);
  [request waitForSync];
  Check(state.waitCount == 0, "no final flush during an active transfer");
  state.downloads.totalUnitCount = 2000;
  state.uploads.completedUnitCount = 1000;
  [request syncDidChange];
  Check(results.count == 0, "wait includes downloads");
  state.downloads.completedUnitCount = 2000;
  [request syncDidChange];
  Check(state.waitCount == 1 && results.count == 0, "downloads finish before final flush");
  state.acknowledgement(nil);
  Check(results.count == 1 && [results[0] boolValue], "acknowledgement after downloads allows unmount");

  state = [[TestSyncState alloc] init];
  state.uploads.completedUnitCount = 1000;
  results = [NSMutableArray array];
  request = Request(state, results);
  [request waitForSync];
  state.acknowledgement([NSError errorWithDomain:NSFileProviderErrorDomain
      code:NSFileProviderErrorCannotSynchronize userInfo:nil]);
  state.uploads.completedUnitCount = 1000;
  [request syncDidChange];
  Check(results.count == 0, "sync errors never auto-unmount");
  [request cancel];
}

static void TestChangesDuringFinalBarrier(void) {
  TestSyncState *state = [[TestSyncState alloc] init];
  state.uploads.completedUnitCount = 1000;
  NSMutableArray *results = [NSMutableArray array];
  HeadlessUnmount *request = Request(state, results);
  [request waitForSync];
  Check(state.waitCount == 1, "initial idle state starts final flush");

  // The first barrier predates a new file. Its success cannot be reused when
  // that file's byte progress later reaches 100 percent.
  state.uploads.totalUnitCount = 2000;
  [request syncDidChange];
  state.acknowledgement(nil);
  Check(results.count == 0, "old acknowledgement cannot unmount a new upload");
  state.uploads.completedUnitCount = 2000;
  [request syncDidChange];
  Check(state.waitCount == 2 && results.count == 0, "new upload needs a fresh final flush");
  state.acknowledgement(nil);
  Check(results.count == 1 && [results[0] boolValue], "unmount only after fresh acknowledgement");

  state = [[TestSyncState alloc] init];
  state.uploads.completedUnitCount = 1000;
  results = [NSMutableArray array];
  request = Request(state, results);
  [request waitForSync];
  state.uploads.totalUnitCount = 2000;
  state.uploads.completedUnitCount = 2000;
  [request syncDidChange];
  state.acknowledgement(nil);
  Check(state.waitCount == 2 && results.count == 0,
        "coalesced progress changes require a fresh flush even if already idle");
  [request cancel];
  state.acknowledgement(nil);
  Check(results.count == 1 && ![results[0] boolValue], "dismiss cancels the replacement flush too");
}

static void TestPendingForceAndIsolation(void) {
  TestSyncState *first = [[TestSyncState alloc] init];
  first.uploads.completedUnitCount = 1000;
  NSMutableArray *firstResults = [NSMutableArray array];
  HeadlessUnmount *firstRequest = Request(first, firstResults);
  [firstRequest start];
  Check(first.waitCount == 1 && firstResults.count == 0, "idle still checks queued changes");

  TestSyncState *second = [[TestSyncState alloc] init];
  NSMutableArray *secondResults = [NSMutableArray array];
  HeadlessUnmount *secondRequest = Request(second, secondResults);
  [secondRequest waitForSync];
  second.uploads.completedUnitCount = 1000;
  [secondRequest syncDidChange];
  [firstRequest hidePopover];
  Check(firstRequest.waiting, "switching visible popovers does not cancel another device's wait");
  first.acknowledgement(nil);
  Check(firstResults.count == 1 && secondResults.count == 0, "devices wait independently");
  [secondRequest forceUnmount];
  second.acknowledgement(nil);
  Check(secondResults.count == 1 && [secondResults[0] boolValue], "force bypasses barrier once");
  Check(second.evictionCount == 0, "force skips cache eviction so dirty data is preserved");

  TestSyncState *released = [[TestSyncState alloc] init];
  released.uploads.completedUnitCount = 1000;
  NSMutableArray *releasedResults = [NSMutableArray array];
  @autoreleasepool {
    HeadlessUnmount *releasedRequest = Request(released, releasedResults);
    [releasedRequest waitForSync];
  }
  released.acknowledgement(nil);
  Check(releasedResults.count == 0, "late acknowledgement does not resurrect a request");
}

static void TestCacheEviction(void) {
  TestSyncState *state = [[TestSyncState alloc] init];
  state.uploads.completedUnitCount = 1000;
  state.delayEviction = YES;
  NSMutableArray *results = [NSMutableArray array];
  HeadlessUnmount *request = Request(state, results);
  [request waitForSync];
  state.acknowledgement(nil);
  Check(state.evictionCount == 1 && results.count == 0,
        "acknowledged files must be safely evicted before unmount");
  state.evictionCompletion(nil);
  Check(results.count == 1 && [results[0] boolValue], "successful cache eviction allows unmount");

  state = [[TestSyncState alloc] init];
  state.uploads.completedUnitCount = 1000;
  state.delayEviction = YES;
  results = [NSMutableArray array];
  request = Request(state, results);
  [request waitForSync];
  state.acknowledgement(nil);
  state.evictionCompletion([NSError errorWithDomain:NSFileProviderErrorDomain
      code:NSFileProviderErrorUnsyncedEdits userInfo:nil]);
  [request syncDidChange];
  Check(results.count == 0 && state.waitCount == 1,
        "failed eviction stays mounted instead of discarding local edits");
  [request forceUnmount];
  Check(results.count == 1 && [results[0] boolValue], "explicit force can bypass failed eviction");

  state = [[TestSyncState alloc] init];
  state.uploads.completedUnitCount = 1000;
  state.delayEviction = YES;
  results = [NSMutableArray array];
  request = Request(state, results);
  [request waitForSync];
  state.acknowledgement(nil);
  [request cancel];
  state.evictionCompletion(nil);
  Check(results.count == 1 && ![results[0] boolValue],
        "dismiss during eviction prevents delayed auto-unmount");

  state = [[TestSyncState alloc] init];
  state.uploads.completedUnitCount = 1000;
  state.delayEviction = YES;
  results = [NSMutableArray array];
  request = Request(state, results);
  [request waitForSync];
  state.acknowledgement(nil);
  state.uploads.totalUnitCount = 2000;
  [request syncDidChange];
  state.evictionCompletion([NSError errorWithDomain:NSFileProviderErrorDomain
      code:NSFileProviderErrorUnsyncedEdits userInfo:nil]);
  Check(results.count == 0 && state.waitCount == 1, "new upload during eviction prevents unmount");
  state.uploads.completedUnitCount = 2000;
  [request syncDidChange];
  Check(state.waitCount == 2, "new upload after eviction requires a fresh acknowledgement");
  state.acknowledgement(nil);
  Check(state.evictionCount == 2 && results.count == 0, "fresh upload also requires fresh cache eviction");
  state.evictionCompletion(nil);
  Check(results.count == 1 && [results[0] boolValue], "fresh acknowledgement and eviction allow unmount");
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    if (argc > 1 && strcmp(argv[1], "--render") == 0) {
      [NSApplication sharedApplication];
      TestSyncState *state = [[TestSyncState alloc] init];
      MTPUnmountController *request = [[MTPUnmountController alloc]
          initWithSyncState:state statusButton:nil];
      [request waitForSync];
      NSPopover *popover = [request valueForKey:@"popover"];
      NSView *view = popover.contentViewController.view;
      NSWindow *window = [[NSWindow alloc] initWithContentRect:view.bounds
          styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
      window.contentView = view;
      for (NSString *theme in @[@"light", @"dark", @"error", @"unknown"]) {
        if ([theme isEqualToString:@"error"]) {
          state.uploads.completedUnitCount = 1000;
          [request syncDidChange];
          state.acknowledgement([NSError errorWithDomain:NSCocoaErrorDomain
              code:NSFileWriteOutOfSpaceError userInfo:@{
                NSLocalizedDescriptionKey : @"The device is full. Free some space and try again."
              }]);
        } else if ([theme isEqualToString:@"unknown"]) {
          [request cancel];
          state = [[TestSyncState alloc] init];
          state.uploads.totalUnitCount = -1;
          request = [[MTPUnmountController alloc] initWithSyncState:state statusButton:nil];
          [request waitForSync];
          popover = [request valueForKey:@"popover"];
          view = popover.contentViewController.view;
          window.contentView = view;
        }
        view.appearance = [NSAppearance appearanceNamed:[theme isEqualToString:@"light"]
            ? NSAppearanceNameAqua : NSAppearanceNameDarkAqua];
        [window setContentSize:popover.contentSize];
        __block NSData *png;
        [view.appearance performAsCurrentDrawingAppearance:^{
          view.wantsLayer = YES;
          view.layer.backgroundColor = NSColor.windowBackgroundColor.CGColor;
          [view layoutSubtreeIfNeeded];
          NSTextField *title = [request valueForKey:@"titleLabel"];
          NSRect titleFrame = [title convertRect:title.bounds toView:view];
          Check(fabs(NSMaxY(view.bounds) - NSMaxY(titleFrame) - 16) < 0.5,
                "title keeps the same top inset in every popover state");
          NSStackView *stack = view.subviews.firstObject;
          NSView *actions = stack.views.lastObject;
          NSRect actionsFrame = [actions convertRect:actions.bounds toView:view];
          NSLog(@"Popover %@: height=%.1f, stack fit=%.1f, action inset=%.1f",
                theme, NSHeight(view.bounds), stack.fittingSize.height,
                NSMinY(actionsFrame) - NSMinY(view.bounds));
          NSLog(@"Popover sizes: content=%@, preferred=%@", NSStringFromSize(popover.contentSize),
                NSStringFromSize(popover.contentViewController.preferredContentSize));
          Check(fabs(NSMinY(actionsFrame) - NSMinY(view.bounds) - 12) < 0.5,
                "popover fits its actions without empty space below");
          NSBitmapImageRep *bitmap = [view bitmapImageRepForCachingDisplayInRect:view.bounds];
          [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
          png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        }];
        NSString *path = [NSString stringWithFormat:@"build/icon-preview/sync-popover-%@.png", theme];
        Check([png writeToFile:path atomically:YES], "save popover rendering");
      }
      [request cancel];
      return 0;
    }
    if ((argc > 1 && strcmp(argv[1], "--preview") == 0) ||
        [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.sudomaker.MacMTP.SyncPreview"]) {
      [NSApplication sharedApplication];
      [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
      TestSyncState *state = [[TestSyncState alloc] init];
      NSStatusItem *item = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
      item.button.image = [NSImage imageWithSystemSymbolName:@"arrow.triangle.2.circlepath"
                                   accessibilityDescription:@"Sync preview"];
      MTPUnmountController *request = [[MTPUnmountController alloc]
          initWithSyncState:state statusButton:item.button];
      request.completionHandler = ^(BOOL unmount) { (void)unmount; [NSApp stop:nil]; };
      [request waitForSync];
      [NSApp run];
      return 0;
    }
    TestProgress();
    TestWaitAndDismiss();
    TestDownloadsAndErrors();
    TestChangesDuringFinalBarrier();
    TestPendingForceAndIsolation();
    TestCacheEviction();
    std::puts("Sync tests passed.");
  }
  return 0;
}
