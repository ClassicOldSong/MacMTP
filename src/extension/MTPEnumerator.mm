#import "MTPEnumerator.h"

@interface MTPEnumerator ()
@property(nonatomic, copy) NSFileProviderItemIdentifier containerIdentifier;
@property(nonatomic, weak) id<MTPEnumerationSource> source;
@property(nonatomic, strong, nullable) NSSet<NSFileProviderItemIdentifier> *lastIdentifiers;
@property(nonatomic) BOOL invalidated;
@end

@implementation MTPEnumerator

- (instancetype)initWithContainerIdentifier:(NSFileProviderItemIdentifier)containerIdentifier
                                      source:(id<MTPEnumerationSource>)source {
  self = [super init];
  if (self) {
    _containerIdentifier = [containerIdentifier copy];
    _source = source;
  }
  return self;
}

- (void)invalidate {
  self.invalidated = YES;
}

- (void)enumerateItemsForObserver:(id<NSFileProviderEnumerationObserver>)observer
                   startingAtPage:(NSFileProviderPage)page {
  (void)page;
  [self.source loadItemsForContainer:self.containerIdentifier
                          completion:^(NSArray<id<NSFileProviderItem>> *items, NSError *error) {
    if (self.invalidated) {
      [observer finishEnumeratingWithError:[NSError errorWithDomain:NSCocoaErrorDomain
                                                               code:NSUserCancelledError
                                                           userInfo:nil]];
      return;
    }
    if (error != nil) {
      [observer finishEnumeratingWithError:error];
      return;
    }
    NSMutableSet<NSFileProviderItemIdentifier> *identifiers = [NSMutableSet setWithCapacity:items.count];
    for (id<NSFileProviderItem> item in items) {
      [identifiers addObject:item.itemIdentifier];
    }
    self.lastIdentifiers = identifiers;
    [observer didEnumerateItems:items];
    [observer finishEnumeratingUpToPage:nil];
  }];
}

- (void)enumerateChangesForObserver:(id<NSFileProviderChangeObserver>)observer
                     fromSyncAnchor:(NSFileProviderSyncAnchor)syncAnchor {
  (void)syncAnchor;
  [self.source loadItemsForContainer:self.containerIdentifier
                          completion:^(NSArray<id<NSFileProviderItem>> *items, NSError *error) {
    if (self.invalidated) {
      [observer finishEnumeratingWithError:[NSError errorWithDomain:NSCocoaErrorDomain
                                                               code:NSUserCancelledError
                                                           userInfo:nil]];
      return;
    }
    if (error != nil) {
      [observer finishEnumeratingWithError:error];
      return;
    }

    NSMutableSet<NSFileProviderItemIdentifier> *current = [NSMutableSet setWithCapacity:items.count];
    for (id<NSFileProviderItem> item in items) {
      [current addObject:item.itemIdentifier];
    }
    if (self.lastIdentifiers != nil) {
      NSMutableSet<NSFileProviderItemIdentifier> *deleted = [self.lastIdentifiers mutableCopy];
      [deleted minusSet:current];
      if (deleted.count > 0) {
        [observer didDeleteItemsWithIdentifiers:deleted.allObjects];
      }
    }
    if (items.count > 0) {
      [observer didUpdateItems:items];
    }
    self.lastIdentifiers = current;
    [observer finishEnumeratingChangesUpToSyncAnchor:[self newSyncAnchor] moreComing:NO];
  }];
}

- (void)currentSyncAnchorWithCompletionHandler:(void (^)(NSFileProviderSyncAnchor))completionHandler {
  completionHandler([self newSyncAnchor]);
}

- (NSFileProviderSyncAnchor)newSyncAnchor {
  NSString *anchor = NSUUID.UUID.UUIDString;
  return [anchor dataUsingEncoding:NSUTF8StringEncoding];
}

@end

