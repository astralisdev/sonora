// ui.m — the menu bar item and its per-app volume sliders.

#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <ServiceManagement/ServiceManagement.h>
#import "engine.h"
#include "sonora.h"

static const CGFloat kRowWidth = 300, kRowHeight = 40, kMaxVolume = 150;

static BOOL reduceMotion(void) {
    return NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
}

// Fades and slides a freshly shown view into place. Core Animation runs on the
// render server, so this works while the menu is tracking the mouse.
static void animateIn(NSView *view, NSUInteger index) {
    if (reduceMotion() || !view.layer) return;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @0;
    fade.toValue = @1;
    CABasicAnimation *slide = [CABasicAnimation animationWithKeyPath:@"transform.translation.y"];
    slide.fromValue = @(-6);
    slide.toValue = @0;
    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[ fade, slide ];
    group.duration = 0.22;
    group.beginTime = CACurrentMediaTime() + 0.025 * index;
    group.fillMode = kCAFillModeBackwards; // stay hidden until its turn
    group.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [view.layer addAnimation:group forKey:@"appear"];
}

#pragma mark - Activity bars

// Three little bars that bounce while an app is playing.
@interface SNActivityView : NSView
- (void)setPlaying:(BOOL)playing call:(BOOL)call;
@end

@implementation SNActivityView {
    NSArray<CALayer *> *_bars;
    BOOL _playing, _call;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.wantsLayer = YES;
    NSMutableArray *bars = [NSMutableArray new];
    for (int i = 0; i < 3; i++) {
        CALayer *bar = [CALayer layer];
        bar.anchorPoint = CGPointMake(0.5, 0);
        bar.bounds = CGRectMake(0, 0, 2, frame.size.height);
        bar.position = CGPointMake(1 + i * 4, 0);
        bar.cornerRadius = 1;
        [self.layer addSublayer:bar];
        [bars addObject:bar];
    }
    _bars = bars;
    return self;
}

- (void)setPlaying:(BOOL)playing call:(BOOL)call {
    _playing = playing;
    _call = call;
    [self update];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self update];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self update]; // layer animations are dropped when a view leaves its window
}

- (void)update {
    __block CGColorRef color = NULL;
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        NSColor *c = !self->_playing ? NSColor.tertiaryLabelColor
                     : self->_call   ? NSColor.systemGreenColor
                                     : NSColor.controlAccentColor;
        color = CGColorRetain(c.CGColor);
    }];
    static const double durations[] = {0.42, 0.55, 0.36};
    static const double lows[] = {0.3, 0.45, 0.25};
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [_bars enumerateObjectsUsingBlock:^(CALayer *bar, NSUInteger i, BOOL *stop) {
        bar.backgroundColor = color;
        [bar removeAllAnimations];
        if (!self->_playing || !self.window) {
            bar.transform = CATransform3DMakeScale(1, 0.3, 1);
            return;
        }
        bar.transform = CATransform3DIdentity;
        if (reduceMotion()) return;
        CABasicAnimation *bounce = [CABasicAnimation animationWithKeyPath:@"transform.scale.y"];
        bounce.fromValue = @(lows[i]);
        bounce.toValue = @1;
        bounce.duration = durations[i];
        bounce.autoreverses = YES;
        bounce.repeatCount = HUGE_VALF;
        bounce.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        bounce.timeOffset = durations[i] * 0.6 * i; // out of step with each other
        [bar addAnimation:bounce forKey:@"bounce"];
    }];
    [CATransaction commit];
    CGColorRelease(color);
}
@end

#pragma mark - App row

@interface SNAppRow : NSView
@property(nonatomic, copy) NSString *key;
@property(nonatomic) NSUInteger index; // position in the menu, for the staggered entrance
- (instancetype)initWithApp:(SNApp *)app;
@end

@implementation SNAppRow {
    NSButton *_iconButton;
    NSTextField *_name, *_percent;
    NSSlider *_slider;
    SNActivityView *_activity;
    BOOL _muted;
}

- (instancetype)initWithApp:(SNApp *)app {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, kRowWidth, kRowHeight)])) return nil;
    self.wantsLayer = YES;
    _key = app.key;
    SNEngine *engine = [SNEngine shared];
    _muted = [engine mutedForKey:app.key];
    NSString *title = app.name ?: app.key;

    _iconButton = [NSButton buttonWithImage:app.icon target:self action:@selector(toggleMute:)];
    _iconButton.frame = NSMakeRect(14, 6, 28, 28);
    _iconButton.bordered = NO;
    _iconButton.imageScaling = NSImageScaleProportionallyUpOrDown;
    _iconButton.toolTip = @"Click to mute or unmute";
    _iconButton.accessibilityLabel = [NSString stringWithFormat:@"Mute %@", title];
    [self addSubview:_iconButton];

    NSString *label = app.inCall ? [title stringByAppendingString:@"  ·  in call"] : title;
    NSFont *nameFont = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    _name = [NSTextField labelWithString:label];
    _name.font = nameFont;
    _name.lineBreakMode = NSLineBreakByTruncatingTail;
    // Measure the text itself (+4 pt for the cell's padding); a truncating
    // label's intrinsic size isn't reliable.
    CGFloat nameWidth = MIN(ceil([label sizeWithAttributes:@{NSFontAttributeName : nameFont}].width) + 4, 176);
    _name.frame = NSMakeRect(50, 22, nameWidth, 15);
    [self addSubview:_name];

    _activity = [[SNActivityView alloc] initWithFrame:NSMakeRect(50 + nameWidth + 6, 25, 10, 9)];
    [_activity setPlaying:app.playing call:app.inCall];
    [self addSubview:_activity];

    _slider = [NSSlider sliderWithValue:[engine volumeForKey:app.key] minValue:0 maxValue:kMaxVolume
                                 target:self action:@selector(sliderMoved:)];
    _slider.frame = NSMakeRect(48, 3, 196, 20);
    _slider.controlSize = NSControlSizeSmall;
    _slider.continuous = YES;
    _slider.accessibilityLabel = [NSString stringWithFormat:@"%@ volume", title];
    [self addSubview:_slider];

    _percent = [NSTextField labelWithString:@""];
    _percent.frame = NSMakeRect(246, 6, 46, 15);
    _percent.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    _percent.alignment = NSTextAlignmentRight;
    [self addSubview:_percent];

    [self updateLabelsAnimated:NO];
    return self;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) animateIn(self, _index);
}

- (void)updateLabelsAnimated:(BOOL)animated {
    _percent.stringValue = _muted ? @"Muted" : [NSString stringWithFormat:@"%d%%", (int)lround(_slider.doubleValue)];
    _percent.textColor = _muted ? NSColor.secondaryLabelColor : NSColor.labelColor;
    _slider.enabled = !_muted;
    CGFloat alpha = _muted ? 0.35 : 1.0;
    if (animated && !reduceMotion()) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.18;
            self->_iconButton.animator.alphaValue = alpha;
        }];
    } else {
        _iconButton.alphaValue = alpha;
    }
}

- (void)sliderMoved:(NSSlider *)slider {
    double v = round(slider.doubleValue);
    if (fabs(v - 100) < 3) v = 100; // snap to the "untouched" level
    slider.doubleValue = v;
    [self updateLabelsAnimated:NO];
    [[SNEngine shared] setVolume:v muted:_muted forKey:_key];
}

- (void)toggleMute:(id)sender {
    _muted = !_muted;
    [self updateLabelsAnimated:YES];
    [[SNEngine shared] setVolume:round(_slider.doubleValue) muted:_muted forKey:_key];
}
@end

#pragma mark - Permission banner

@interface SNBannerView : NSView
@end

@implementation SNBannerView
- (instancetype)init {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, kRowWidth, 56)])) return nil;
    self.wantsLayer = YES;
    NSImageView *icon = [NSImageView imageViewWithImage:
        [NSImage imageWithSystemSymbolName:@"exclamationmark.triangle.fill" accessibilityDescription:@"Warning"]];
    icon.contentTintColor = NSColor.systemOrangeColor;
    icon.frame = NSMakeRect(16, 18, 22, 20);
    [self addSubview:icon];

    NSTextField *title = [NSTextField labelWithString:@"Sonora can't hear your apps"];
    title.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    title.frame = NSMakeRect(48, 34, 240, 16);
    [self addSubview:title];

    NSTextField *detail = [NSTextField wrappingLabelWithString:
        @"Allow System Audio Recording for Sonora. Volumes are paused until then."];
    detail.font = [NSFont systemFontOfSize:10];
    detail.textColor = NSColor.secondaryLabelColor;
    detail.frame = NSMakeRect(48, 4, 240, 30);
    [self addSubview:detail];
    return self;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) animateIn(self, 0);
}
@end

#pragma mark - App delegate

@interface SNAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@end

@implementation SNAppDelegate {
    NSStatusItem *_statusItem;
    NSMenu *_menu;
    BOOL _menuOpen;

    // "Deciphering" title animation
    NSTimer *_scrambleTimer, *_clearTimer;
    NSString *_text;          // text we're deciphering towards
    NSMutableArray<NSNumber *> *_reveal; // frame at which each character becomes final
    NSInteger _frame;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    _statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    [self updateStatusIcon];
    _statusItem.button.toolTip = @"Sonora — per-app volume";

    _menu = [NSMenu new];
    _menu.delegate = self;
    _menu.autoenablesItems = NO;
    _statusItem.menu = _menu;

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(appsChanged:) name:SNEngineAppsDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(volumeChanged:) name:SNEngineVolumeDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(permissionChanged:) name:SNEnginePermissionDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(callStarted:) name:SNEngineCallDuckingDidStartNotification object:nil];
    [[SNEngine shared] start];
    [self announce:@"SONORA"];
}

- (void)applicationWillTerminate:(NSNotification *)note {
    [[SNEngine shared] shutdown];
}

- (void)updateStatusIcon {
    BOOL problem = [SNEngine shared].permissionProblem;
    NSImage *image = [NSImage imageWithSystemSymbolName:problem ? @"exclamationmark.triangle" : @"slider.vertical.3"
                               accessibilityDescription:@"Sonora"];
    image.template = YES;
    _statusItem.button.image = image;
}

- (void)menuNeedsUpdate:(NSMenu *)menu { [self rebuildMenu]; }
- (void)menuWillOpen:(NSMenu *)menu { _menuOpen = YES; }
- (void)menuDidClose:(NSMenu *)menu { _menuOpen = NO; }

- (void)appsChanged:(NSNotification *)note {
    // An app started or stopped while the menu is showing. Rebuilding would
    // cancel a slider drag in progress, so wait until the mouse is released.
    if (!_menuOpen) return;
    if (NSEvent.pressedMouseButtons != 0) {
        [self performSelector:@selector(appsChanged:) withObject:note afterDelay:0.3 inModes:@[NSRunLoopCommonModes]];
        return;
    }
    [self rebuildMenu];
}

- (void)permissionChanged:(NSNotification *)note {
    [self updateStatusIcon];
    if ([SNEngine shared].permissionProblem) [self announce:@"NO PERMISSION"];
    [self appsChanged:note];
}

- (void)callStarted:(NSNotification *)note {
    [self announce:@"CALL MODE"];
}

#pragma mark - Deciphering title

static NSString *const kGlyphs = @"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789#%&@$*+=<>?/";

- (void)volumeChanged:(NSNotification *)note {
    NSString *key = note.userInfo[@"key"];
    NSString *name = key;
    for (SNApp *app in [SNEngine shared].apps) if ([app.key isEqualToString:key]) name = app.name;
    name = name.uppercaseString;
    if (name.length > 12) name = [[name substringToIndex:11] stringByAppendingString:@"…"];
    BOOL muted = [note.userInfo[@"muted"] boolValue];
    NSString *level = muted ? @"MUTED" : [NSString stringWithFormat:@"%d%%", (int)lround([note.userInfo[@"percent"] doubleValue])];
    [self announce:[NSString stringWithFormat:@"%@ %@", name, level]];
}

// Shows `text` in the menu bar, scrambling each character before it settles,
// then goes back to the plain icon after a pause.
- (void)announce:(NSString *)text {
    NSString *old = _statusItem.button.title;
    BOOL showing = old.length > 0;
    _text = [text copy];
    _reveal = [NSMutableArray new];
    for (NSUInteger i = 0; i < text.length; i++) {
        BOOL same = showing && i < old.length && [old characterAtIndex:i] == [text characterAtIndex:i] && _scrambleTimer == nil;
        [_reveal addObject:@(same ? 0 : _frame + 3 + (NSInteger)i * 2)];
    }
    [_clearTimer invalidate];
    _clearTimer = nil;

    if (reduceMotion()) {
        [self setTitleText:text];
    } else if (!_scrambleTimer) {
        __weak SNAppDelegate *weakSelf = self;
        _scrambleTimer = [NSTimer timerWithTimeInterval:0.035 repeats:YES block:^(NSTimer *t) { [weakSelf tick]; }];
        [NSRunLoop.mainRunLoop addTimer:_scrambleTimer forMode:NSRunLoopCommonModes]; // keeps going while the menu is open
        [self tick];
    }
    if (!_scrambleTimer) [self scheduleClear];
}

- (void)tick {
    _frame++;
    NSMutableString *shown = [NSMutableString stringWithCapacity:_text.length];
    BOOL done = YES;
    for (NSUInteger i = 0; i < _text.length; i++) {
        unichar c = [_text characterAtIndex:i];
        if (c == ' ' || _frame >= _reveal[i].integerValue) {
            [shown appendFormat:@"%C", c];
        } else {
            [shown appendFormat:@"%C", [kGlyphs characterAtIndex:arc4random_uniform((uint32_t)kGlyphs.length)]];
            done = NO;
        }
    }
    [self setTitleText:shown];
    if (done) {
        [_scrambleTimer invalidate];
        _scrambleTimer = nil;
        [self scheduleClear];
    }
}

- (void)scheduleClear {
    __weak SNAppDelegate *weakSelf = self;
    _clearTimer = [NSTimer timerWithTimeInterval:2.5 repeats:NO block:^(NSTimer *t) {
        SNAppDelegate *strongSelf = weakSelf;
        [strongSelf setTitleText:@""];
        strongSelf->_clearTimer = nil;
    }];
    [NSRunLoop.mainRunLoop addTimer:_clearTimer forMode:NSRunLoopCommonModes];
}

- (void)setTitleText:(NSString *)text {
    NSStatusBarButton *button = _statusItem.button;
    if (text.length == 0) {
        button.title = @"";
        button.imagePosition = NSImageOnly;
        _statusItem.length = NSSquareStatusItemLength;
        return;
    }
    button.attributedTitle = [[NSAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName : [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium]}];
    button.imagePosition = NSImageLeft;
    _statusItem.length = NSVariableStatusItemLength;
}

#pragma mark - Menu

- (void)rebuildMenu {
    [_menu removeAllItems];
    SNEngine *engine = [SNEngine shared];

    NSString *output = engine.outputDeviceName;
    [_menu addItem:[NSMenuItem sectionHeaderWithTitle:output ? [@"Output: " stringByAppendingString:output] : @"Sonora"]];

    if (engine.permissionProblem) {
        NSMenuItem *banner = [NSMenuItem new];
        banner.view = [SNBannerView new];
        [_menu addItem:banner];
        [self addItem:@"Open Privacy Settings…" action:@selector(openPrivacySettings:) key:@""];
        [self addItem:@"Try Again" action:@selector(retryPermission:) key:@""];
        [_menu addItem:NSMenuItem.separatorItem];
    }

    NSUInteger index = 0;
    if (engine.apps.count == 0) {
        NSMenuItem *empty = [[NSMenuItem alloc] initWithTitle:@"No apps are playing audio" action:nil keyEquivalent:@""];
        empty.enabled = NO;
        [_menu addItem:empty];
    }
    for (SNApp *app in engine.apps) [self addRow:app index:index++];

    if (engine.callActive) {
        // macOS's own mic filter (Voice Isolation) removes music and noise far
        // better than a call app's echo canceller. It's chosen per app in
        // Control Center and no API lets another app open it, so Sonora explains
        // where it is.
        [_menu addItem:NSMenuItem.separatorItem];
        NSMenuItem *mic = [self addItem:@"Filter Music Out of Your Mic…" action:@selector(explainVoiceIsolation:) key:@""];
        mic.image = [NSImage imageWithSystemSymbolName:@"mic.fill" accessibilityDescription:nil];
    }

    [_menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *reset = [self addItem:@"Reset All Levels" action:@selector(resetAll:) key:@""];
    reset.toolTip = @"Set every app back to 100%, its normal volume.";

    // During calls: how much to lower everything except the call.
    NSMenuItem *duckItem = [[NSMenuItem alloc] initWithTitle:@"During Calls" action:nil keyEquivalent:@""];
    duckItem.toolTip = @"Turn other apps down while you're in a call, so music from your speakers "
                       @"doesn't reach your microphone.";
    NSMenu *duckMenu = [NSMenu new];
    double current = engine.callDuckDB;
    NSArray *choices = @[ @[ @"Leave Other Apps Alone", @0 ], @[ @"Lower Other Apps a Little", @6 ],
                          @[ @"Lower Other Apps a Lot", @12 ], @[ @"Mute Other Apps", @100 ] ];
    for (NSArray *choice in choices) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:choice[0] action:@selector(setCallDuck:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = choice[1];
        item.state = fabs([choice[1] doubleValue] - current) < 0.5 ? NSControlStateValueOn : NSControlStateValueOff;
        [duckMenu addItem:item];
    }
    duckItem.submenu = duckMenu;
    [_menu addItem:duckItem];

    NSMenuItem *login = [self addItem:@"Launch at Login" action:@selector(toggleLogin:) key:@""];
    login.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;

    [self addItem:@"Sonora on GitHub" action:@selector(openGitHub:) key:@""];
    [_menu addItem:NSMenuItem.separatorItem];
    [self addItem:@"Quit Sonora" action:@selector(quit:) key:@"q"];
}

- (void)addRow:(SNApp *)app index:(NSUInteger)index {
    SNAppRow *row = [[SNAppRow alloc] initWithApp:app];
    row.index = index;
    NSMenuItem *item = [NSMenuItem new];
    item.view = row;
    [_menu addItem:item];
}

- (NSMenuItem *)addItem:(NSString *)title action:(SEL)action key:(NSString *)key {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
    item.target = self;
    [_menu addItem:item];
    return item;
}

- (void)resetAll:(id)sender { [[SNEngine shared] resetAll]; }

// A Control Center label in the user's language, so the instructions name
// exactly what they see on screen. Falls back to English.
static NSString *controlCenterString(NSString *key, NSString *fallback) {
    static NSDictionary *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = [NSDictionary dictionaryWithContentsOfFile:
            @"/System/Library/CoreServices/ControlCenter.app/Contents/Resources/AudioVideo.loctable"];
    });
    for (NSString *lang in NSLocale.preferredLanguages) { // e.g. "it-IT"
        NSString *full = [lang stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
        NSString *base = [lang componentsSeparatedByString:@"-"].firstObject;
        for (NSString *code in @[ full, base ]) {
            NSString *s = table[code][key];
            if ([s isKindOfClass:NSString.class]) return s;
        }
    }
    NSString *en = table[@"en"][key];
    return [en isKindOfClass:NSString.class] ? en : fallback;
}

- (void)explainVoiceIsolation:(id)sender {
    NSString *callApp = @"your call app";
    for (SNApp *app in [SNEngine shared].apps) if (app.inCall) callApp = app.name;
    NSString *module = controlCenterString(@"AudioVideoModule", @"Audio and Video Controls");
    NSString *micMode = controlCenterString(@"Mic Mode", @"Mic Mode");
    NSString *isolation = controlCenterString(@"Voice Isolation", @"Voice Isolation");

    NSAlert *alert = [NSAlert new];
    alert.messageText = [NSString stringWithFormat:@"Turn on “%@”", isolation];
    alert.informativeText = [NSString stringWithFormat:
        @"It makes the other person hear only your voice, not music or noise in the room.\n\n"
        @"1. While the call is on, click the camera/microphone icon that appears in the menu bar (“%@”). "
        @"If you don't see it, open Control Center.\n"
        @"2. Click “%@”.\n"
        @"3. Choose “%@”.\n\n"
        @"macOS remembers this for %@. If it says the app doesn't support it, use "
        @"During Calls → Mute Other Apps in Sonora instead.",
        module, micMode, isolation, callApp];
    alert.icon = [NSImage imageWithSystemSymbolName:@"mic.fill" accessibilityDescription:nil];
    [alert addButtonWithTitle:@"OK"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

- (void)setCallDuck:(NSMenuItem *)sender {
    [SNEngine shared].callDuckDB = [sender.representedObject doubleValue];
}

- (void)openPrivacySettings:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:
        @"x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"]];
}

- (void)retryPermission:(id)sender { [[SNEngine shared] retryPermission]; }

- (void)toggleLogin:(id)sender {
    SMAppService *svc = SMAppService.mainAppService;
    NSError *err = nil;
    BOOL ok = svc.status == SMAppServiceStatusEnabled ? [svc unregisterAndReturnError:&err] : [svc registerAndReturnError:&err];
    if (!ok) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Couldn't change the login item";
        alert.informativeText = err.localizedDescription ?: @"Move Sonora to /Applications and try again.";
        [NSApp activateIgnoringOtherApps:YES];
        [alert runModal];
    }
}

- (void)openGitHub:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://github.com/astralisdev/sonora"]];
}

- (void)quit:(id)sender { [NSApp terminate:nil]; }
@end

void SNRun(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyAccessory; // menu bar only, no Dock icon
        static SNAppDelegate *delegate;
        delegate = [SNAppDelegate new];
        app.delegate = delegate;
        [app run];
    }
}

void SNSnapshot(const char *path) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSArray<SNApp *> *apps = [SNEngine scanApps];
        SNBannerView *banner = [SNBannerView new];
        CGFloat top = banner.frame.size.height;
        NSView *stack = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kRowWidth, kRowHeight * apps.count + top)];
        stack.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        banner.frameOrigin = NSMakePoint(0, kRowHeight * apps.count);
        [stack addSubview:banner];
        [apps enumerateObjectsUsingBlock:^(SNApp *app, NSUInteger i, BOOL *stop) {
            SNAppRow *row = [[SNAppRow alloc] initWithApp:app];
            row.frameOrigin = NSMakePoint(0, kRowHeight * (apps.count - 1 - i));
            [stack addSubview:row];
        }];
        NSBitmapImageRep *rep = [stack bitmapImageRepForCachingDisplayInRect:stack.bounds];
        [stack cacheDisplayInRect:stack.bounds toBitmapImageRep:rep];
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(path) atomically:YES];
        printf("wrote %lu rows to %s\n", (unsigned long)apps.count, path);
    }
}
