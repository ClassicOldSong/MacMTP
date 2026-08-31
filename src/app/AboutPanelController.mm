#import "AboutPanelController.h"

@implementation AboutPanelController

- (instancetype)init {
  NSRect frame = NSMakeRect(0, 0, 420, 290);
  NSPanel *panel = [[NSPanel alloc]
      initWithContentRect:frame
                styleMask:(NSWindowStyleMaskTitled |
                           NSWindowStyleMaskClosable |
                           NSWindowStyleMaskFullSizeContentView)
                  backing:NSBackingStoreBuffered
                    defer:NO];
  panel.title = @"About MacMTP";
  panel.titleVisibility = NSWindowTitleHidden;
  panel.titlebarAppearsTransparent = YES;
  panel.backgroundColor = NSColor.clearColor;
  panel.opaque = NO;
  panel.hasShadow = YES;
  panel.movableByWindowBackground = YES;
  panel.releasedWhenClosed = NO;
  panel.hidesOnDeactivate = NO;
  panel.animationBehavior = NSWindowAnimationBehaviorUtilityWindow;

  NSVisualEffectView *backdrop = [[NSVisualEffectView alloc] initWithFrame:frame];
  backdrop.material = NSVisualEffectMaterialHUDWindow;
  backdrop.blendingMode = NSVisualEffectBlendingModeBehindWindow;
  backdrop.state = NSVisualEffectStateActive;
  backdrop.wantsLayer = YES;
  backdrop.layer.cornerRadius = 18;
  backdrop.layer.masksToBounds = YES;
  panel.contentView = backdrop;

  NSImageView *icon = [[NSImageView alloc] initWithFrame:NSZeroRect];
  NSURL *iconURL = [[NSBundle mainBundle] URLForResource:@"MacMTP" withExtension:@"icns"];
  icon.image = iconURL != nil ? [[NSImage alloc] initWithContentsOfURL:iconURL] : nil;
  icon.imageScaling = NSImageScaleProportionallyUpOrDown;
  [icon.widthAnchor constraintEqualToConstant:68].active = YES;
  [icon.heightAnchor constraintEqualToConstant:68].active = YES;

  NSTextField *name = [NSTextField labelWithString:@"MacMTP"];
  name.font = [NSFont systemFontOfSize:28 weight:NSFontWeightBold];
  name.alignment = NSTextAlignmentCenter;

  NSString *versionNumber = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
  NSString *buildNumber = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"];
  NSString *versionText = [versionNumber isEqualToString:buildNumber]
                              ? [NSString stringWithFormat:@"Version %@", versionNumber]
                              : [NSString stringWithFormat:@"Version %@ (%@)", versionNumber, buildNumber];
  NSTextField *version = [NSTextField labelWithString:versionText];
  version.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
  version.textColor = NSColor.secondaryLabelColor;
  version.alignment = NSTextAlignmentCenter;

  NSTextField *summary = [NSTextField labelWithString:@"MTP devices in Finder."];
  summary.font = [NSFont systemFontOfSize:13];
  summary.textColor = NSColor.labelColor;
  summary.alignment = NSTextAlignmentCenter;
  summary.maximumNumberOfLines = 1;

  NSButton *githubLink =
      [NSButton buttonWithTitle:@"GitHub"
                        target:nil
                        action:@selector(openGitHub:)];
  githubLink.bordered = NO;
  githubLink.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
  githubLink.contentTintColor = NSColor.linkColor;

  NSTextField *copyright =
      [NSTextField labelWithString:@"Copyright © 2026 Yukino Song"];
  copyright.font = [NSFont systemFontOfSize:11];
  copyright.textColor = NSColor.secondaryLabelColor;
  copyright.alignment = NSTextAlignmentCenter;

  NSStackView *stack =
      [NSStackView stackViewWithViews:@[
        icon, name, version, summary, githubLink, copyright
      ]];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeCenterX;
  stack.spacing = 10;
  [stack setCustomSpacing:3 afterView:name];
  [stack setCustomSpacing:18 afterView:version];
  [stack setCustomSpacing:5 afterView:summary];
  [stack setCustomSpacing:12 afterView:githubLink];
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  [backdrop addSubview:stack];

  [NSLayoutConstraint activateConstraints:@[
    [stack.centerXAnchor constraintEqualToAnchor:backdrop.centerXAnchor],
    [stack.centerYAnchor constraintEqualToAnchor:backdrop.centerYAnchor constant:8],
    [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:backdrop.leadingAnchor constant:36],
    [stack.trailingAnchor constraintLessThanOrEqualToAnchor:backdrop.trailingAnchor constant:-36]
  ]];

  self = [super initWithWindow:panel];
  if (self) {
    githubLink.target = self;
    [panel center];
  }
  return self;
}

- (void)openGitHub:(id)sender {
  (void)sender;
  [NSWorkspace.sharedWorkspace
      openURL:[NSURL URLWithString:@"https://github.com/ClassicOldSong/MacMTP"]];
}

- (void)showPanel {
  [NSApp activateIgnoringOtherApps:YES];
  [self.window center];
  [self.window makeKeyAndOrderFront:nil];
}

@end
