// welcome.m — the first-launch window: what Sonora does, the audio
// permission, and opening at login.

#import <AppKit/AppKit.h>
#import <ServiceManagement/ServiceManagement.h>
#import "engine.h"
#import "welcome.h"

static NSString *const kWelcomeDoneKey = @"WelcomeDone";

@interface SNWelcomeController () <NSWindowDelegate>
- (void)prepareSnapshot;
@end

#pragma mark - Deciphering credit

// A label that scrambles from one text into another, character by character,
// the same effect as the menu bar title. Works on whole characters (emoji
// included), and pads the shorter text so the two line up.
@interface SNDecipherLabel : NSTextField
- (void)cycleBetween:(NSString *)a and:(NSString *)b times:(NSInteger)times;
- (void)stop;
@end

@implementation SNDecipherLabel {
    NSArray<NSString *> *_from, *_to;   // characters of the current and next text
    NSArray<NSString *> *_texts;
    NSInteger _shown, _remaining, _frame;
    NSTimer *_timer;
}

static NSArray<NSString *> *characters(NSString *s) {
    NSMutableArray *out = [NSMutableArray new];
    [s enumerateSubstringsInRange:NSMakeRange(0, s.length) options:NSStringEnumerationByComposedCharacterSequences
                       usingBlock:^(NSString *c, NSRange r, NSRange e, BOOL *stop) { [out addObject:c]; }];
    return out;
}

static NSArray<NSString *> *padded(NSArray<NSString *> *chars, NSUInteger length) {
    NSMutableArray *out = [chars mutableCopy];
    NSUInteger extra = length - chars.count;
    for (NSUInteger i = 0; i < extra / 2; i++) [out insertObject:@" " atIndex:0]; // keep it centred
    while (out.count < length) [out addObject:@" "];
    return out;
}

- (void)cycleBetween:(NSString *)a and:(NSString *)b times:(NSInteger)times {
    _texts = @[ a, b ];
    _shown = 0;
    _remaining = times * 2; // there and back
    self.stringValue = a;
    if (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) return;
    [self scheduleNext:2.0];
}

- (void)scheduleNext:(NSTimeInterval)delay {
    [_timer invalidate];
    if (_remaining <= 0) return;
    __weak SNDecipherLabel *weakSelf = self;
    _timer = [NSTimer timerWithTimeInterval:delay repeats:NO block:^(NSTimer *t) { [weakSelf startTransition]; }];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)startTransition {
    NSArray *from = characters(_texts[_shown]), *to = characters(_texts[1 - _shown]);
    NSUInteger length = MAX(from.count, to.count);
    _from = padded(from, length);
    _to = padded(to, length);
    _frame = 0;
    __weak SNDecipherLabel *weakSelf = self;
    _timer = [NSTimer timerWithTimeInterval:0.035 repeats:YES block:^(NSTimer *t) { [weakSelf tick]; }];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)tick {
    static NSString *const glyphs = @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789#%&@$*+=<>?/";
    _frame++;
    NSMutableString *s = [NSMutableString new];
    BOOL done = YES;
    for (NSUInteger i = 0; i < _to.count; i++) {
        NSInteger revealAt = 4 + (NSInteger)i; // left to right, ~1 s for the whole line
        NSString *target = _to[i];
        if (_frame >= revealAt) {
            [s appendString:target];
        } else if ([target isEqualToString:@" "] && [_from[i] isEqualToString:@" "]) {
            [s appendString:@" "];
        } else {
            [s appendFormat:@"%C", [glyphs characterAtIndex:arc4random_uniform((uint32_t)glyphs.length)]];
            done = NO;
        }
    }
    self.stringValue = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (done) {
        [_timer invalidate];
        _shown = 1 - _shown;
        _remaining--;
        [self scheduleNext:_shown == 1 ? 2.2 : 2.0];
    }
}

- (void)stop {
    [_timer invalidate];
    _timer = nil;
}

- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:NSCursor.pointingHandCursor];
}

- (void)mouseDown:(NSEvent *)event {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://github.com/astralisdev"]];
}
@end

@implementation SNWelcomeController {
    NSButton *_allowButton, *_loginCheckbox;
    NSTextField *_allowStatus;
    SNDecipherLabel *_credit;
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
    [_credit cycleBetween:@"Made with ❤️ by @astralisdev" and:@"eyes on the stars!" times:4];
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

    _credit = [SNDecipherLabel labelWithString:@""];
    _credit.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium];
    _credit.textColor = NSColor.tertiaryLabelColor;
    _credit.alignment = NSTextAlignmentCenter;
    _credit.toolTip = @"github.com/astralisdev";
    [_credit.widthAnchor constraintEqualToConstant:300].active = YES;

    NSStackView *content = [NSStackView stackViewWithViews:@[ appIcon, title, subtitle, steps, done, _credit ]];
    content.orientation = NSUserInterfaceLayoutOrientationVertical;
    content.alignment = NSLayoutAttributeCenterX;
    content.spacing = 10;
    [content setCustomSpacing:22 afterView:subtitle];
    [content setCustomSpacing:26 afterView:steps];
    [content setCustomSpacing:18 afterView:done];
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

- (void)prepareSnapshot {
    [self buildWindow];
    [self updatePermission];
    [_credit cycleBetween:@"Made with ❤️ by @astralisdev" and:@"eyes on the stars!" times:0];
}

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
    [_credit stop];
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
        [c prepareSnapshot];
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
