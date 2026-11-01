#import "MTPDomainSyncState.h"

static void *SyncProgressObservation = &SyncProgressObservation;

@interface MTPDomainSyncState ()
@property(nonatomic, strong) NSFileProviderManager *manager;
@property(nonatomic, strong) NSArray<NSProgress *> *observedProgresses;
@property(nonatomic) BOOL updateScheduled;
@end

@implementation MTPDomainSyncState

- (instancetype)initWithDomain:(NSFileProviderDomain *)domain {
  self = [super init];
  if (self) {
    _domain = domain;
    _manager = [NSFileProviderManager managerForDomain:domain];
    if (_manager == nil) {
      return nil;
    }
    _uploads = [_manager globalProgressForKind:NSProgressFileOperationKindUploading];
    _downloads = [_manager globalProgressForKind:NSProgressFileOperationKindDownloading];
    _observedProgresses = @[_uploads, _downloads];
    for (NSProgress *progress in _observedProgresses) {
      for (NSString *key in @[@"finished", @"totalUnitCount", @"completedUnitCount"]) {
        [progress addObserver:self forKeyPath:key options:0 context:SyncProgressObservation];
      }
    }
  }
  return self;
}

- (void)dealloc {
  for (NSProgress *progress in _observedProgresses) {
    for (NSString *key in @[@"finished", @"totalUnitCount", @"completedUnitCount"]) {
      [progress removeObserver:self forKeyPath:key context:SyncProgressObservation];
    }
  }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                      change:(NSDictionary *)change context:(void *)context {
  if (context != SyncProgressObservation) {
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    return;
  }
  // The API delivers progress on the main queue. Defer one turn to coalesce its
  // individual count changes and avoid acting on a half-updated progress object.
  if (self.updateScheduled) {
    return;
  }
  self.updateScheduled = YES;
  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    typeof(self) self = weakSelf;
    self.updateScheduled = NO;
    if (self.changeHandler != nil) {
      self.changeHandler();
    }
  });
}

- (BOOL)busy {
  return !self.uploads.finished || !self.downloads.finished;
}

- (double)fractionCompleted {
  double total = 0;
  double completed = 0;
  for (NSProgress *progress in @[self.uploads, self.downloads]) {
    if (!progress.finished) {
      if (progress.totalUnitCount <= 0) {
        return -1;
      }
      total += progress.totalUnitCount;
      completed += MIN(progress.completedUnitCount, progress.totalUnitCount);
    }
  }
  return total > 0 ? MAX(0, MIN(1, completed / total)) : 1;
}

- (void)waitForSync:(void (^)(NSError *))completion {
  // A finished progress object alone is not a flush: on-disk changes may still
  // be queued. This production API waits for the extension's acknowledgements.
  [self.manager waitForChangesOnItemsBelowItemWithIdentifier:NSFileProviderRootContainerItemIdentifier
                                        completionHandler:^(NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
  }];
}

- (void)evictSyncedContents:(void (^)(NSError *))completion {
  // The system refuses to evict unsynced, non-evictable, or in-use files. Never
  // unlink the cache or force eviction: a Finder move may hold the only copy.
  [self.manager evictItemWithIdentifier:NSFileProviderRootContainerItemIdentifier
                    completionHandler:^(NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
  }];
}

@end
