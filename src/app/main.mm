#import <AppKit/AppKit.h>

#import "AppDelegate.h"

int main(int argc, const char *argv[]) {
  (void)argc;
  (void)argv;
  @autoreleasepool {
    NSApplication *application = [NSApplication sharedApplication];
    AppDelegate *delegate = [[AppDelegate alloc] init];
    application.delegate = delegate;
    [application run];
  }
  return 0;
}

