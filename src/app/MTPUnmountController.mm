#import "MTPUnmountController.h"

@interface MTPUnmountController ()
@property(nonatomic, weak) NSStatusBarButton *statusButton;
@property(nonatomic, strong) NSPopover *popover;
@property(nonatomic, strong) NSTextField *titleLabel;
@property(nonatomic, strong) NSTextField *detailLabel;
@property(nonatomic, strong) NSProgressIndicator *progressBar;
@property(nonatomic, strong) NSTextField *progressLabel;
@property(nonatomic, strong) NSButton *forceButton;
@property(nonatomic, strong) NSStackView *contentStack;
@property(nonatomic) BOOL waiting;
@property(nonatomic) BOOL barrierInFlight;
@property(nonatomic) BOOL syncChangedDuringBarrier;
@property(nonatomic) BOOL finished;
@property(nonatomic, strong) NSError *syncError;
@end

@implementation MTPUnmountController

- (instancetype)initWithSyncState:(MTPDomainSyncState *)syncState
                    statusButton:(NSStatusBarButton *)statusButton {
  self = [super init];
  if (self) {
    _syncState = syncState;
    _statusButton = statusButton;
  }
  return self;
}

- (void)start {
  if (!self.syncState.busy) {
    // Still check the system's queue, even if no transfer is running yet.
    [self waitForSync];
    return;
  }
  [NSApp activateIgnoringOtherApps:YES];
  NSAlert *alert = [[NSAlert alloc] init];
  alert.alertStyle = NSAlertStyleWarning;
  alert.messageText = [NSString stringWithFormat:@"%@ Is Still Syncing", self.syncState.domain.displayName];
  alert.informativeText = @"Wait for your files to finish copying before disconnecting. Force Unmount stops syncing; unsynced files will be kept on this Mac.";
  [alert addButtonWithTitle:@"Wait for Sync"];
  [alert addButtonWithTitle:@"Cancel"];
  [alert addButtonWithTitle:@"Force Unmount"];
  alert.buttons[1].keyEquivalent = @"\e";
  alert.buttons[2].hasDestructiveAction = YES;
  NSModalResponse response = [alert runModal];
  if (self.finished) {
    return;
  }
  if (response == NSAlertFirstButtonReturn) {
    [self waitForSync];
  } else if (response == NSAlertThirdButtonReturn) {
    [self forceUnmount];
  } else {
    [self cancel];
  }
}

- (void)waitForSync {
  if (self.finished || self.waiting) {
    return;
  }
  self.waiting = YES;
  [self showPopover];
  [self confirmSyncBeforeUnmount];
}

- (void)syncDidChange {
  if (!self.waiting || self.finished) {
    return;
  }
  // An acknowledgement only covers changes up to that barrier. Any subsequent
  // progress change requires a new barrier, even if progress is already idle.
  if (self.barrierInFlight) {
    self.syncChangedDuringBarrier = YES;
  }
  [self updatePresentation];
  [self confirmSyncBeforeUnmount];
}

- (void)confirmSyncBeforeUnmount {
  if (!self.waiting || self.finished || self.syncError != nil ||
      self.syncState.busy || self.barrierInFlight) {
    return;
  }
  // Start the final flush after transfers become idle, not at the beginning of
  // a potentially long upload. NSProgress finishing is not a sync acknowledgement.
  self.barrierInFlight = YES;
  self.syncChangedDuringBarrier = NO;
  __weak typeof(self) weakSelf = self;
  [self.syncState waitForSync:^(NSError *error) {
    typeof(self) self = weakSelf;
    if (self == nil || self.finished) {
      return;
    }
    self.syncError = error;
    if (error != nil) {
      self.barrierInFlight = NO;
      NSLog(@"Final sync failed for %@: %@", self.syncState.domain.identifier, error);
      [self updatePresentation];
    } else if (self.syncChangedDuringBarrier || self.syncState.busy) {
      self.barrierInFlight = NO;
      [self updatePresentation];
      [self confirmSyncBeforeUnmount];
    } else {
      [self.syncState evictSyncedContents:^(NSError *evictionError) {
        typeof(self) self = weakSelf;
        if (self == nil || self.finished) {
          return;
        }
        self.barrierInFlight = NO;
        if (self.syncChangedDuringBarrier || self.syncState.busy) {
          // A new write may also have made eviction fail. Wait for that work
          // and verify again rather than using an obsolete sync check.
          [self updatePresentation];
          [self confirmSyncBeforeUnmount];
        } else if (evictionError != nil) {
          NSLog(@"Could not evict clean cache for %@: %@ (details=%@)",
                self.syncState.domain.identifier, evictionError, evictionError.userInfo);
          self.syncError = evictionError;
          [self updatePresentation];
        } else {
          [self finish:YES];
        }
      }];
    }
  }];
}

- (void)updatePresentation {
  self.titleLabel.stringValue = self.syncError != nil ? @"Could Not Finish Syncing"
                                                     : self.syncState.domain.displayName;
  self.detailLabel.stringValue = self.syncError != nil
      ? self.syncError.localizedDescription
      : @"Keep this popover open to unmount automatically.\nKeep the device connected.";
  self.detailLabel.toolTip = self.syncError.localizedDescription;
  double fraction = self.syncState.fractionCompleted;
  BOOL indeterminate = fraction < 0 || !self.syncState.busy;
  self.progressBar.indeterminate = indeterminate;
  if (indeterminate && self.syncError == nil) {
    [self.progressBar startAnimation:nil];
  } else {
    [self.progressBar stopAnimation:nil];
    self.progressBar.doubleValue = MAX(0, fraction) * 100;
  }
  self.progressLabel.stringValue = self.syncError != nil ? @"Device will stay mounted."
      : indeterminate ? @"Waiting for pending changes…"
      : [NSString stringWithFormat:@"Syncing — %ld%%", (long)MIN(99, fraction * 100)];
  self.forceButton.hidden = self.syncError == nil;
  NSView *view = self.popover.contentViewController.view;
  if (view != nil) {
    // Let Auto Layout size the popover to its current text and controls, with
    // the same bottom inset in normal and error states.
    [view layoutSubtreeIfNeeded];
    NSSize size = NSMakeSize(312, self.contentStack.fittingSize.height + 16 + 12);
    [view setFrameSize:size];
    self.popover.contentViewController.preferredContentSize = size;
    self.popover.contentSize = size;
    [view layoutSubtreeIfNeeded];
  }
}

- (void)showPopover {
  if (self.finished) {
    return;
  }
  if (self.popover == nil) {
    NSViewController *content = [[NSViewController alloc] init];
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 312, 1)];
    content.view = view;
    self.titleLabel = [NSTextField labelWithString:self.syncState.domain.displayName];
    self.titleLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    self.titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.detailLabel = [NSTextField wrappingLabelWithString:
        @"Keep this popover open to unmount automatically.\nKeep the device connected."];
    self.detailLabel.font = [NSFont systemFontOfSize:12];
    self.detailLabel.maximumNumberOfLines = 3;
    self.detailLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.detailLabel.preferredMaxLayoutWidth = 280;
    self.progressBar = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.progressBar.style = NSProgressIndicatorStyleBar;
    self.progressBar.minValue = 0;
    self.progressBar.maxValue = 100;
    self.progressBar.accessibilityLabel = @"Device sync progress";
    self.progressLabel = [NSTextField labelWithString:@"Waiting for pending changes…"];
    self.progressLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.progressLabel.textColor = NSColor.secondaryLabelColor;
    NSButton *dismiss = [NSButton buttonWithTitle:@"Dismiss" target:self action:@selector(cancel)];
    dismiss.bezelStyle = NSBezelStyleRounded;
    dismiss.toolTip = @"Keep syncing without automatically unmounting.";
    dismiss.keyEquivalent = @"\e";
    self.forceButton = [NSButton buttonWithTitle:@"Force Unmount" target:self action:@selector(forceUnmount)];
    self.forceButton.bezelStyle = NSBezelStyleRounded;
    self.forceButton.hasDestructiveAction = YES;
    self.forceButton.hidden = YES;
    NSView *actions = [[NSView alloc] initWithFrame:NSZeroRect];
    [actions addSubview:self.forceButton];
    [actions addSubview:dismiss];
    self.forceButton.translatesAutoresizingMaskIntoConstraints = NO;
    dismiss.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
      [actions.heightAnchor constraintEqualToConstant:24],
      [self.forceButton.leadingAnchor constraintEqualToAnchor:actions.leadingAnchor],
      [self.forceButton.centerYAnchor constraintEqualToAnchor:actions.centerYAnchor],
      [dismiss.trailingAnchor constraintEqualToAnchor:actions.trailingAnchor],
      [dismiss.centerYAnchor constraintEqualToAnchor:actions.centerYAnchor]
    ]];
    NSStackView *stack = [NSStackView stackViewWithViews:
        @[self.titleLabel, self.detailLabel, self.progressBar, self.progressLabel, actions]];
    self.contentStack = stack;
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    [stack setCustomSpacing:4 afterView:self.titleLabel];
    [stack setCustomSpacing:4 afterView:self.progressBar];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
      [stack.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:16],
      [stack.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-16],
      [stack.topAnchor constraintEqualToAnchor:view.topAnchor constant:16],
      [stack.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:-12],
      [view.widthAnchor constraintEqualToConstant:312],
      [self.titleLabel.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
      [self.detailLabel.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
      [self.progressBar.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
      [actions.widthAnchor constraintEqualToAnchor:stack.widthAnchor]
    ]];
    self.popover = [[NSPopover alloc] init];
    self.popover.contentViewController = content;
    self.popover.behavior = NSPopoverBehaviorApplicationDefined;
    self.popover.delegate = self;
  }
  [self updatePresentation];
  if (!self.finished && self.statusButton != nil) {
    self.popover.delegate = self;
    [NSApp activateIgnoringOtherApps:YES];
    [self.popover showRelativeToRect:self.statusButton.bounds
                             ofView:self.statusButton preferredEdge:NSRectEdgeMinY];
    [self.popover.contentViewController.view.window makeKeyWindow];
  }
}

- (void)popoverDidClose:(NSNotification *)notification {
  (void)notification;
  [self cancel];
}

- (void)hidePopover {
  // Switching to another device's popover keeps this explicit wait request alive.
  self.popover.delegate = nil;
  self.popover.animates = NO;
  [self.popover close];
  self.popover.animates = YES;
}

- (void)cancel { [self finish:NO]; }
- (void)forceUnmount { [self finish:YES]; }

- (void)finish:(BOOL)unmount {
  if (self.finished) {
    return;
  }
  self.finished = YES;
  self.waiting = NO;
  self.popover.delegate = nil;
  [self.popover close];
  void (^completion)(BOOL) = self.completionHandler;
  self.completionHandler = nil;
  if (completion != nil) {
    completion(unmount);
  }
}

@end
