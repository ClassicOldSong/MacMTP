#import "AppDelegate.h"

#import "AboutPanelController.h"
#import "MTPDevice.h"
#import "MTPDeviceMonitor.h"

#import <FileProvider/FileProvider.h>
#import <ServiceManagement/ServiceManagement.h>

static NSString *const AutoMountDefaultsKey = @"AutoMountDevices";
static NSString *const AutoOpenDefaultsKey = @"AutoOpenMountedDevices";

@interface AppDelegate ()
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) NSMenu *statusMenu;
@property(nonatomic, strong) NSMenuItem *startAtLoginMenuItem;
@property(nonatomic, strong) MTPDeviceMonitor *deviceMonitor;
@property(nonatomic, strong) NSArray<MTPDeviceDescriptor *> *devices;
@property(nonatomic, strong) NSDictionary<NSString *, NSFileProviderDomain *> *domains;
@property(nonatomic, strong) NSMutableSet<NSString *> *manuallyUnmounted;
@property(nonatomic, strong) NSMutableSet<NSString *> *pendingDomainOperations;
@property(nonatomic, strong) NSMutableDictionary<NSString *, dispatch_block_t> *pendingDisconnectRemovals;
@property(nonatomic, strong) AboutPanelController *aboutPanelController;
@property(nonatomic) dispatch_queue_t scanQueue;
@property(nonatomic) BOOL scanInFlight;
@property(nonatomic) BOOL scanAgain;
@property(nonatomic) BOOL domainsLoaded;
@property(nonatomic) BOOL domainLoadInFlight;
@property(nonatomic) BOOL statusMenuOpen;
@property(nonatomic) BOOL menuRebuildPending;
@property(nonatomic) BOOL terminating;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  (void)notification;
  [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
  [[NSUserDefaults standardUserDefaults] registerDefaults:@{
    AutoMountDefaultsKey : @NO,
    AutoOpenDefaultsKey : @NO,
  }];

  NSURL *appIconURL = [[NSBundle mainBundle] URLForResource:@"MacMTP"
                                               withExtension:@"icns"];
  NSImage *appIcon = appIconURL != nil ? [[NSImage alloc] initWithContentsOfURL:appIconURL] : nil;
  if (appIcon != nil) {
    NSApp.applicationIconImage = appIcon;
  } else {
    NSLog(@"MacMTP.icns is missing or invalid.");
  }

  self.devices = @[];
  self.domains = @{};
  self.manuallyUnmounted = [NSMutableSet set];
  self.pendingDomainOperations = [NSMutableSet set];
  self.pendingDisconnectRemovals = [NSMutableDictionary dictionary];
  self.scanQueue =
      dispatch_queue_create("com.sudomaker.MacMTP.device-scan", DISPATCH_QUEUE_SERIAL);

  self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
  NSURL *trayIconURL = [[NSBundle mainBundle] URLForResource:@"MacMTPTray"
                                               withExtension:@"png"];
  NSImage *image = trayIconURL != nil ? [[NSImage alloc] initWithContentsOfURL:trayIconURL] : nil;
  if (image != nil) {
    image.size = NSMakeSize(18, 18);
    [image setTemplate:YES];
    self.statusItem.button.image = image;
  } else {
    self.statusItem.button.title = @"MTP";
  }

  self.statusMenu = [[NSMenu alloc] initWithTitle:@"MacMTP"];
  self.statusMenu.delegate = self;
  self.statusItem.menu = self.statusMenu;
  [self rebuildMenu];

  __weak typeof(self) weakSelf = self;
  self.deviceMonitor = [[MTPDeviceMonitor alloc] initWithChangeHandler:^{
    [weakSelf refreshDevices];
  }];
  [self.deviceMonitor start];
  [self refreshDevices];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
  (void)notification;
  [self.deviceMonitor stop];
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
  if (self.terminating) {
    return NSTerminateLater;
  }
  self.terminating = YES;
  [self.deviceMonitor stop];
  for (dispatch_block_t removal in self.pendingDisconnectRemovals.allValues) {
    dispatch_block_cancel(removal);
  }
  [self.pendingDisconnectRemovals removeAllObjects];
  self.statusItem.button.enabled = NO;

  [NSFileProviderManager removeAllDomainsWithCompletionHandler:^(NSError *error) {
    if (error != nil) {
      NSLog(@"Could not remove File Provider domains while quitting: %@", error);
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      [sender replyToApplicationShouldTerminate:YES];
    });
  }];
  return NSTerminateLater;
}

- (void)menuWillOpen:(NSMenu *)menu {
  (void)menu;
  self.statusMenuOpen = YES;
  [self updateStartAtLoginMenuItem];
  [self refreshDevices];
}

- (void)menuDidClose:(NSMenu *)menu {
  (void)menu;
  self.statusMenuOpen = NO;
  if (self.menuRebuildPending) {
    self.menuRebuildPending = NO;
    [self rebuildMenu];
  }
}

- (void)refreshDevices {
  if (self.terminating) {
    return;
  }
  if (self.scanInFlight) {
    self.scanAgain = YES;
    return;
  }
  self.scanInFlight = YES;

  __weak typeof(self) weakSelf = self;
  dispatch_async(self.scanQueue, ^{
    NSError *error = nil;
    NSArray<MTPDeviceDescriptor *> *devices = MTPDetectDevices(&error);
    dispatch_async(dispatch_get_main_queue(), ^{
      typeof(self) self = weakSelf;
      if (self == nil || self.terminating) {
        return;
      }
      self.scanInFlight = NO;
      if (error != nil) {
        NSLog(@"MTP device scan failed: %@", error);
      } else {
        NSMutableDictionary<NSString *, MTPDeviceDescriptor *> *mergedDevices =
            [NSMutableDictionary dictionaryWithCapacity:devices.count];
        for (MTPDeviceDescriptor *device in devices) {
          mergedDevices[device.domainIdentifier] = device;
        }
        for (MTPDeviceDescriptor *device in self.devices) {
          if (mergedDevices[device.domainIdentifier] == nil &&
              (self.domains[device.domainIdentifier] != nil ||
               MTPDomainDeviceIsPhysicallyConnected(device.domainIdentifier))) {
            mergedDevices[device.domainIdentifier] = device;
          }
        }
        self.devices = [mergedDevices.allValues
            sortedArrayUsingComparator:^NSComparisonResult(MTPDeviceDescriptor *left,
                                                            MTPDeviceDescriptor *right) {
              NSComparisonResult nameResult =
                  [left.displayName localizedStandardCompare:right.displayName];
              return nameResult != NSOrderedSame
                         ? nameResult
                         : [left.domainIdentifier compare:right.domainIdentifier];
            }];
        if (self.domainsLoaded) {
          [self reconcileDomains];
          [self rebuildMenu];
        } else {
          [self refreshDomainsAndReconcile];
        }
      }
      if (self.scanAgain) {
        self.scanAgain = NO;
        [self refreshDevices];
      }
    });
  });
}

- (void)refreshDomainsAndReconcile {
  if (self.terminating || self.domainLoadInFlight) {
    return;
  }
  self.domainLoadInFlight = YES;
  __weak typeof(self) weakSelf = self;
  [NSFileProviderManager getDomainsWithCompletionHandler:^(NSArray<NSFileProviderDomain *> *domains,
                                                            NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      typeof(self) self = weakSelf;
      if (self == nil || self.terminating) {
        return;
      }
      self.domainLoadInFlight = NO;
      if (error != nil) {
        NSLog(@"Could not read File Provider domains: %@", error);
        [self rebuildMenu];
        return;
      }

      NSMutableDictionary<NSString *, NSFileProviderDomain *> *byIdentifier = [NSMutableDictionary dictionary];
      for (NSFileProviderDomain *domain in domains) {
        byIdentifier[domain.identifier] = domain;
      }
      self.domains = byIdentifier;
      self.domainsLoaded = YES;
      [self refreshDevices];
    });
  }];
}

- (void)reconcileDomains {
  if (self.terminating) {
    return;
  }
  BOOL removingLegacyDomains = NO;
  for (NSFileProviderDomain *domain in self.domains.allValues) {
    if (!MTPDomainIdentifierUsesStableIdentity(domain.identifier)) {
      removingLegacyDomains = YES;
      NSLog(@"Removing legacy File Provider domain %@.", domain.displayName);
      [self removeDomain:domain reportErrors:NO];
      continue;
    }
    dispatch_block_t pendingRemoval = self.pendingDisconnectRemovals[domain.identifier];
    if ([self.manuallyUnmounted containsObject:domain.identifier]) {
      if (pendingRemoval != nil) {
        dispatch_block_cancel(pendingRemoval);
        [self.pendingDisconnectRemovals removeObjectForKey:domain.identifier];
      }
      [self removeDomain:domain reportErrors:NO];
      continue;
    }
    if (MTPDomainDeviceIsPhysicallyConnected(domain.identifier)) {
      if (pendingRemoval != nil) {
        dispatch_block_cancel(pendingRemoval);
        [self.pendingDisconnectRemovals removeObjectForKey:domain.identifier];
      }
      continue;
    }
    if (pendingRemoval == nil) {
      NSString *identifier = [domain.identifier copy];
      __weak typeof(self) weakSelf = self;
      dispatch_block_t removal = dispatch_block_create(DISPATCH_BLOCK_INHERIT_QOS_CLASS, ^{
        typeof(self) self = weakSelf;
        if (self == nil) {
          return;
        }
        [self.pendingDisconnectRemovals removeObjectForKey:identifier];
        NSFileProviderDomain *currentDomain = self.domains[identifier];
        if (!self.terminating &&
            currentDomain != nil &&
            !MTPDomainDeviceIsPhysicallyConnected(identifier)) {
          NSLog(@"Removing disconnected File Provider domain %@ (%@).",
                currentDomain.displayName,
                identifier);
          [self removeDomain:currentDomain reportErrors:NO];
        }
      });
      self.pendingDisconnectRemovals[identifier] = removal;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                     dispatch_get_main_queue(),
                     removal);
    }
  }

  if (removingLegacyDomains) {
    return;
  }

  if ([[NSUserDefaults standardUserDefaults] boolForKey:AutoMountDefaultsKey]) {
    for (MTPDeviceDescriptor *device in self.devices) {
      if (self.domains[device.domainIdentifier] == nil &&
          ![self.manuallyUnmounted containsObject:device.domainIdentifier] &&
          MTPDomainDeviceIsPhysicallyConnected(device.domainIdentifier)) {
        [self addDomainForDevice:device reportErrors:NO];
      }
    }
  }

  for (MTPDeviceDescriptor *device in self.devices) {
    NSFileProviderDomain *domain = self.domains[device.domainIdentifier];
    if (domain != nil &&
        ![self.manuallyUnmounted containsObject:device.domainIdentifier] &&
        (![domain.displayName isEqualToString:device.displayName] ||
         domain.supportsSyncingTrash)) {
      [self addDomainForDevice:device reportErrors:NO];
    }
  }
}

- (void)addDomainForDevice:(MTPDeviceDescriptor *)device reportErrors:(BOOL)reportErrors {
  if (self.terminating ||
      [self.pendingDomainOperations containsObject:device.domainIdentifier]) {
    return;
  }
  [self.pendingDomainOperations addObject:device.domainIdentifier];
  BOOL updatingExistingDomain = self.domains[device.domainIdentifier] != nil;
  NSFileProviderDomain *domain = [[NSFileProviderDomain alloc]
      initWithIdentifier:device.domainIdentifier
             displayName:device.displayName];
  domain.supportsSyncingTrash = NO;
  NSLog(@"%@ File Provider domain %@ (%@).",
        updatingExistingDomain ? @"Updating" : @"Adding",
        device.displayName,
        device.domainIdentifier);
  __weak typeof(self) weakSelf = self;
  [NSFileProviderManager addDomain:domain completionHandler:^(NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      typeof(self) self = weakSelf;
      if (self == nil) {
        return;
      }
      if (error != nil) {
        NSLog(@"Could not mount %@: %@", device.displayName, error);
        if (reportErrors) {
          [self presentOperationError:error title:@"Could Not Mount Device"];
        }
        if (!updatingExistingDomain) {
          [NSFileProviderManager removeDomain:domain completionHandler:^(NSError *cleanupError) {
            if (cleanupError != nil && cleanupError.code != NSFileNoSuchFileError) {
              NSLog(@"Could not clean up failed domain %@: %@", device.displayName, cleanupError);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
              [self.pendingDomainOperations removeObject:device.domainIdentifier];
              if (!self.terminating) {
                [self rebuildMenu];
              }
            });
          }];
          return;
        }
      } else {
        NSMutableDictionary<NSString *, NSFileProviderDomain *> *updatedDomains =
            [self.domains mutableCopy];
        updatedDomains[domain.identifier] = domain;
        self.domains = updatedDomains;
      }
      [self.pendingDomainOperations removeObject:device.domainIdentifier];
      if (!self.terminating) {
        if (error == nil) {
          [self reconcileDomains];
        }
        [self rebuildMenu];
        if (error == nil &&
            !updatingExistingDomain &&
            [[NSUserDefaults standardUserDefaults] boolForKey:AutoOpenDefaultsKey]) {
          [self openDomainInFinder:domain reportErrors:NO];
        }
      }
    });
  }];
}

- (void)removeDomain:(NSFileProviderDomain *)domain reportErrors:(BOOL)reportErrors {
  if (self.terminating ||
      [self.pendingDomainOperations containsObject:domain.identifier]) {
    return;
  }
  dispatch_block_t pendingRemoval = self.pendingDisconnectRemovals[domain.identifier];
  if (pendingRemoval != nil) {
    dispatch_block_cancel(pendingRemoval);
    [self.pendingDisconnectRemovals removeObjectForKey:domain.identifier];
  }
  [self.pendingDomainOperations addObject:domain.identifier];
  __weak typeof(self) weakSelf = self;
  [NSFileProviderManager removeDomain:domain completionHandler:^(NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      typeof(self) self = weakSelf;
      if (self == nil) {
        return;
      }
      if (error != nil) {
        NSLog(@"Could not unmount %@: %@", domain.displayName, error);
        if (reportErrors) {
          [self presentOperationError:error title:@"Could Not Unmount Device"];
        }
      } else {
        NSMutableDictionary<NSString *, NSFileProviderDomain *> *updatedDomains =
            [self.domains mutableCopy];
        [updatedDomains removeObjectForKey:domain.identifier];
        self.domains = updatedDomains;
      }
      [self.pendingDomainOperations removeObject:domain.identifier];
      if (!self.terminating) {
        if (error == nil) {
          [self refreshDevices];
        }
        [self rebuildMenu];
      }
    });
  }];
}

- (void)mountOrUnmountDevice:(NSMenuItem *)sender {
  MTPDeviceDescriptor *device = sender.representedObject;
  NSFileProviderDomain *domain = self.domains[device.domainIdentifier];
  if (domain == nil) {
    [self.manuallyUnmounted removeObject:device.domainIdentifier];
    [self addDomainForDevice:device reportErrors:YES];
  } else {
    [self.manuallyUnmounted addObject:device.domainIdentifier];
    [self removeDomain:domain reportErrors:YES];
  }
}

- (void)openDevice:(NSMenuItem *)sender {
  MTPDeviceDescriptor *device = sender.representedObject;
  NSFileProviderDomain *domain = self.domains[device.domainIdentifier];
  if (domain == nil) {
    return;
  }
  [self openDomainInFinder:domain reportErrors:YES];
}

- (void)openDomainInFinder:(NSFileProviderDomain *)domain reportErrors:(BOOL)reportErrors {
  NSFileProviderManager *manager = [NSFileProviderManager managerForDomain:domain];
  if (manager == nil) {
    NSError *error = [NSError errorWithDomain:NSFileProviderErrorDomain
                                         code:NSFileProviderErrorServerUnreachable
                                     userInfo:@{NSLocalizedDescriptionKey : @"The mounted device is unavailable."}];
    NSLog(@"Could not open %@: %@", domain.displayName, error);
    if (reportErrors) {
      [self presentOperationError:error title:@"Could Not Open Device"];
    }
    return;
  }
  __weak typeof(self) weakSelf = self;
  [manager getUserVisibleURLForItemIdentifier:NSFileProviderRootContainerItemIdentifier
                            completionHandler:^(NSURL *url, NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      typeof(self) self = weakSelf;
      if (self == nil || self.terminating) {
        return;
      }
      if (url != nil) {
        BOOL isAccessing = [url startAccessingSecurityScopedResource];
        NSWorkspaceOpenConfiguration *configuration =
            [NSWorkspaceOpenConfiguration configuration];
        [[NSWorkspace sharedWorkspace]
            openURL:url
            configuration:configuration
            completionHandler:^(NSRunningApplication *application, NSError *openError) {
              (void)application;
              if (isAccessing) {
                [url stopAccessingSecurityScopedResource];
              }
              if (openError != nil) {
                NSLog(@"Could not open %@ in Finder: %@", domain.displayName, openError);
                dispatch_async(dispatch_get_main_queue(), ^{
                  if (reportErrors && !self.terminating) {
                    [self presentOperationError:openError title:@"Could Not Open Device"];
                  }
                });
              }
            }];
      } else if (error != nil) {
        NSLog(@"Could not resolve %@ in Finder: %@", domain.displayName, error);
        if (reportErrors) {
          [self presentOperationError:error title:@"Could Not Open Device"];
        }
      }
    });
  }];
}

- (void)toggleAutoMount:(NSMenuItem *)sender {
  BOOL enabled = sender.state != NSControlStateValueOn;
  [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:AutoMountDefaultsKey];
  sender.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
  if (enabled) {
    [self.manuallyUnmounted removeAllObjects];
    [self reconcileDomains];
  }
  [self rebuildMenu];
}

- (void)toggleAutoOpen:(NSMenuItem *)sender {
  BOOL enabled = sender.state != NSControlStateValueOn;
  [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:AutoOpenDefaultsKey];
  sender.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
  [self rebuildMenu];
}

- (void)toggleStartAtLogin:(NSMenuItem *)sender {
  (void)sender;
  SMAppService *service = SMAppService.mainAppService;
  if (service.status == SMAppServiceStatusRequiresApproval) {
    [SMAppService openSystemSettingsLoginItems];
    return;
  }

  NSError *error = nil;
  BOOL succeeded = service.status == SMAppServiceStatusEnabled
                       ? [service unregisterAndReturnError:&error]
                       : [service registerAndReturnError:&error];
  if (!succeeded) {
    NSLog(@"Could not update Start at Login: %@", error);
    [self presentOperationError:error title:@"Could Not Update Start at Login"];
  }
  [self updateStartAtLoginMenuItem];
}

- (void)updateStartAtLoginMenuItem {
  if (self.startAtLoginMenuItem == nil) {
    return;
  }

  SMAppServiceStatus status = SMAppService.mainAppService.status;
  self.startAtLoginMenuItem.title = status == SMAppServiceStatusRequiresApproval
                                        ? @"Start at Login (Needs Approval)"
                                        : @"Start at Login";
  self.startAtLoginMenuItem.state = status == SMAppServiceStatusEnabled
                                        ? NSControlStateValueOn
                                    : status == SMAppServiceStatusRequiresApproval
                                        ? NSControlStateValueMixed
                                        : NSControlStateValueOff;
}

- (void)showAboutPanel:(id)sender {
  (void)sender;
  if (self.aboutPanelController == nil) {
    self.aboutPanelController = [[AboutPanelController alloc] init];
  }
  [self.aboutPanelController showPanel];
}

- (void)rebuildMenu {
  if (self.statusMenuOpen) {
    self.menuRebuildPending = YES;
    return;
  }
  [self.statusMenu removeAllItems];

  if (self.devices.count == 0) {
    NSMenuItem *empty = [[NSMenuItem alloc] initWithTitle:@"No MTP Devices"
                                                   action:nil
                                            keyEquivalent:@""];
    empty.enabled = NO;
    [self.statusMenu addItem:empty];
  } else {
    for (MTPDeviceDescriptor *device in self.devices) {
      NSMenuItem *deviceItem = [[NSMenuItem alloc] initWithTitle:device.displayName
                                                          action:nil
                                                   keyEquivalent:@""];
      NSMenu *submenu = [[NSMenu alloc] initWithTitle:device.displayName];
      submenu.autoenablesItems = NO;
      BOOL mounted = self.domains[device.domainIdentifier] != nil;

      NSMenuItem *mount = [[NSMenuItem alloc]
          initWithTitle:(mounted ? @"Unmount" : @"Mount")
                 action:@selector(mountOrUnmountDevice:)
          keyEquivalent:@""];
      mount.target = self;
      mount.representedObject = device;
      [submenu addItem:mount];

      NSMenuItem *open = [[NSMenuItem alloc] initWithTitle:@"Open in Finder"
                                                    action:@selector(openDevice:)
                                             keyEquivalent:@""];
      open.target = self;
      open.representedObject = device;
      open.enabled = mounted;
      [submenu addItem:open];

      deviceItem.submenu = submenu;
      [self.statusMenu addItem:deviceItem];
    }
  }

  [self.statusMenu addItem:NSMenuItem.separatorItem];
  NSMenuItem *autoMount = [[NSMenuItem alloc] initWithTitle:@"Auto Mount"
                                                     action:@selector(toggleAutoMount:)
                                              keyEquivalent:@""];
  autoMount.target = self;
  autoMount.state = [[NSUserDefaults standardUserDefaults] boolForKey:AutoMountDefaultsKey]
                        ? NSControlStateValueOn
                        : NSControlStateValueOff;
  [self.statusMenu addItem:autoMount];

  NSMenuItem *autoOpen = [[NSMenuItem alloc] initWithTitle:@"Auto Open"
                                                    action:@selector(toggleAutoOpen:)
                                             keyEquivalent:@""];
  autoOpen.target = self;
  autoOpen.state = [[NSUserDefaults standardUserDefaults] boolForKey:AutoOpenDefaultsKey]
                       ? NSControlStateValueOn
                       : NSControlStateValueOff;
  [self.statusMenu addItem:autoOpen];

  self.startAtLoginMenuItem = [[NSMenuItem alloc] initWithTitle:@"Start at Login"
                                                         action:@selector(toggleStartAtLogin:)
                                                  keyEquivalent:@""];
  self.startAtLoginMenuItem.target = self;
  [self updateStartAtLoginMenuItem];
  [self.statusMenu addItem:self.startAtLoginMenuItem];

  [self.statusMenu addItem:NSMenuItem.separatorItem];
  NSMenuItem *about = [[NSMenuItem alloc] initWithTitle:@"About MacMTP"
                                                 action:@selector(showAboutPanel:)
                                          keyEquivalent:@""];
  about.target = self;
  [self.statusMenu addItem:about];

  NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit MacMTP"
                                                action:@selector(terminate:)
                                         keyEquivalent:@"q"];
  quit.target = NSApp;
  [self.statusMenu addItem:quit];
}

- (void)presentOperationError:(NSError *)error title:(NSString *)title {
  [NSApp activateIgnoringOtherApps:YES];
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = title;
  alert.informativeText = error.localizedDescription;
  alert.alertStyle = NSAlertStyleWarning;
  [alert addButtonWithTitle:@"OK"];
  [alert runModal];
}

@end
