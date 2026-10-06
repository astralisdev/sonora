// welcome.m — the first-launch window: what Sonora does, the audio
// permission, and opening at login.

#import <AppKit/AppKit.h>
#import <ServiceManagement/ServiceManagement.h>
#import "engine.h"
#import "welcome.h"

static NSString *const kWelcomeDoneKey = @"WelcomeDone";

@interface SNWelcomeController () <NSWindowDelegate>
- (void)buildWindow;
- (void)updatePermission;
@end

@implementation SNWelcomeController {
    NSButton *_allowButton, *_loginCheckbox;
    NSTextField *_allowStatus;
    NSTimer *_poll;
    void (^_onDone)(void);
}

+ (BOOL)needsWelcome {
    return ![NSUserDefaults.standardUserDefaults boolForKey:kWelcomeDoneKey];
}

+ (instancetype)shared {
    static SNWelcomeController *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [SNWelcomeController new]; });
    return c;
}

- (void)showWithCompletion:(void (^)(void))done {
    _onDone = [done copy];
    if (!self.window) [self buildWindow];
    [self updatePermission];
    [_poll invalidate];
    __weak SNWelcomeController *weakSelf = self;
    _poll = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { [weakSelf updatePermission]; }];
    [NSApp activateIgnoringOtherApps:YES];
    [self.window center];
    [self.window makeKeyAndOrderFront:nil];
}

#pragma mark - Layout

static NSTextField *label(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *l = [NSTextField wrappingLabelWithString:text];
    l.font = [NSFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    l.selectable = NO;
    return l;
}

// One step: a tinted symbol, a bold title and a short explanation, plus an
// optional control on the right.
static NSView *stepRow(NSString *symbol, NSColor *tint, NSString *title, NSString *detail, NSView *accessory) {
    NSImageView *icon = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil]];
    icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:18 weight:NSFontWeightMedium];
    icon.contentTintColor = tint;
    [icon.widthAnchor constraintEqualToConstant:28].active = YES;

    NSStackView *text = [NSStackView stackViewWithViews:@[
        label(title, 13, NSFontWeightSemibold, NSColor.labelColor),
        label(detail, 11.5, NSFontWeightRegular, NSColor.secondaryLabelColor),
    ]];
    text.orientation = NSUserInterfaceLayoutOrientationVertical;
    text.alignment = NSLayoutAttributeLeading;
    text.spacing = 2;
    [text setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSMutableArray *views = [NSMutableArray arrayWithObjects:icon, text, nil];
    if (accessory) [views addObject:accessory];
    NSStackView *row = [NSStackView stackViewWithViews:views];
    row.alignment = NSLayoutAttributeTop;
    row.spacing = 12;
    return row;
}

- (void)buildWindow {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 480, 520)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                        NSWindowStyleMaskFullSizeContentView
                                                backing:NSBackingStoreBuffered defer:NO];
    w.titlebarAppearsTransparent = YES;
    w.titleVisibility = NSWindowTitleHidden;
    w.movableByWindowBackground = YES;
    w.releasedWhenClosed = NO;
    w.delegate = self;
    self.window = w;

    NSImageView *appIcon = [NSImageView imageViewWithImage:NSApp.applicationIconImage];
    [appIcon.widthAnchor constraintEqualToConstant:84].active = YES;
    [appIcon.heightAnchor constraintEqualToConstant:84].active = YES;

    NSTextField *title = label(@"Welcome to Sonora", 24, NSFontWeightBold, NSColor.labelColor);
    title.alignment = NSTextAlignmentCenter;
    NSTextField *subtitle = label(@"Set the volume of each app on its own, right from the menu bar.",
                                  13, NSFontWeightRegular, NSColor.secondaryLabelColor);
    subtitle.alignment = NSTextAlignmentCenter;

    _allowButton = [NSButton buttonWithTitle:@"Allow…" target:self action:@selector(allow:)];
    _allowButton.bezelColor = NSColor.controlAccentColor;
    _allowStatus = label(@"", 12, NSFontWeightSemibold, NSColor.systemGreenColor);
    NSStackView *allow = [NSStackView stackViewWithViews:@[ _allowButton, _allowStatus ]];
    allow.orientation = NSUserInterfaceLayoutOrientationVertical;
    allow.alignment = NSLayoutAttributeTrailing;

    _loginCheckbox = [NSButton checkboxWithTitle:@"" target:nil action:nil];
    _loginCheckbox.state = NSControlStateValueOn;

    NSStackView *steps = [NSStackView stackViewWithViews:@[
        stepRow(@"waveform", NSColor.systemPurpleColor, @"Let Sonora hear your apps",
                @"macOS will ask for “System Audio Recording”. Sonora needs it to change an app's volume. "
                @"Nothing is recorded or leaves your Mac.", allow),
        stepRow(@"slider.vertical.3", NSColor.controlAccentColor, @"Find Sonora in the menu bar",
                @"Click its icon at the top of the screen, then drag an app's slider. Click an app's icon to mute it.", nil),
        stepRow(@"phone.fill", NSColor.systemGreenColor, @"Better calls",
                @"During a call Sonora turns other apps down, so your music doesn't reach the other person.", nil),
        stepRow(@"power", NSColor.systemOrangeColor, @"Open at login",
                @"Keep Sonora running so your volumes are always applied.", _loginCheckbox),
    ]];
    steps.orientation = NSUserInterfaceLayoutOrientationVertical;
    steps.alignment = NSLayoutAttributeLeading;
    steps.spacing = 18;
    for (NSView *row in steps.arrangedSubviews) [row.widthAnchor constraintEqualToAnchor:steps.widthAnchor].active = YES;

    NSButton *done = [NSButton buttonWithTitle:@"Get Started" target:self action:@selector(done:)];
    done.keyEquivalent = @"\r";
    done.controlSize = NSControlSizeLarge;

    NSStackView *content = [NSStackView stackViewWithViews:@[ appIcon, title, subtitle, steps, done ]];
    content.orientation = NSUserInterfaceLayoutOrientationVertical;
    content.alignment = NSLayoutAttributeCenterX;
    content.spacing = 10;
    [content setCustomSpacing:22 afterView:subtitle];
    [content setCustomSpacing:26 afterView:steps];
    content.edgeInsets = NSEdgeInsetsMake(36, 36, 28, 36);
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [steps.widthAnchor constraintEqualToAnchor:content.widthAnchor constant:-72].active = YES;
    [subtitle.widthAnchor constraintEqualToAnchor:steps.widthAnchor].active = YES;

    NSVisualEffectView *bg = [NSVisualEffectView new];
    bg.material = NSVisualEffectMaterialWindowBackground;
    bg.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    w.contentView = bg;
    [bg addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:bg.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:bg.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:bg.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:bg.bottomAnchor],
        [bg.widthAnchor constraintEqualToConstant:480],
    ]];
}

#pragma mark - Actions

- (void)updatePermission {
    switch ([SNEngine shared].permission) {
        case SNPermissionGranted:
            _allowButton.hidden = YES;
            _allowStatus.stringValue = @"✓ Allowed";
            _allowStatus.textColor = NSColor.systemGreenColor;
            break;
        case SNPermissionDenied:
            _allowButton.hidden = NO;
            _allowButton.title = @"Open Settings…";
            _allowStatus.stringValue = @"Not allowed";
            _allowStatus.textColor = NSColor.systemOrangeColor;
            break;
        default:
            _allowButton.hidden = NO;
            _allowButton.title = @"Allow…";
            _allowStatus.stringValue = @"";
            break;
    }
}

- (void)allow:(id)sender {
    if ([SNEngine shared].permission == SNPermissionDenied) {
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
            @"x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"]];
    } else {
        [[SNEngine shared] requestPermission];
    }
}

- (void)done:(id)sender {
    SMAppService *svc = SMAppService.mainAppService;
    BOOL wantLogin = _loginCheckbox.state == NSControlStateValueOn;
    BOOL isLogin = svc.status == SMAppServiceStatusEnabled;
    if (wantLogin != isLogin) {
        NSError *err = nil;
        if (wantLogin) [svc registerAndReturnError:&err];
        else [svc unregisterAndReturnError:&err];
        if (err) NSLog(@"sonora: login item: %@", err);
    }
    [self.window close];
}

- (void)windowWillClose:(NSNotification *)note {
    [_poll invalidate];
    _poll = nil;
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:kWelcomeDoneKey];
    if (_onDone) {
        void (^done)(void) = _onDone;
        _onDone = nil;
        done();
    }
}
@end

// Debug: renders the welcome window to a PNG.
void SNSnapshotWelcome(const char *path) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        SNWelcomeController *c = [SNWelcomeController shared];
        [c buildWindow];
        [c updatePermission];
        NSView *v = c.window.contentView;
        v.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        [v layoutSubtreeIfNeeded];
        [c.window setContentSize:v.fittingSize];
        [v layoutSubtreeIfNeeded];
        NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
        [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(path) atomically:YES];
    }
}
