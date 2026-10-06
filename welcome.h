// welcome.h — first-launch window.
#import <AppKit/AppKit.h>

@interface SNWelcomeController : NSWindowController
+ (instancetype)shared;
// YES until the user has been through the welcome window once.
+ (BOOL)needsWelcome;
// Shows the window; `done` runs when it closes.
- (void)showWithCompletion:(void (^)(void))done;
@end
