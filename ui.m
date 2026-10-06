// ui.m — the menu bar item and its per-app volume sliders.

#import <AppKit/AppKit.h>
#import <ServiceManagement/ServiceManagement.h>
#import "engine.h"
#include "sonora.h"

static const CGFloat kRowWidth = 300, kRowHeight = 40, kMaxVolume = 150;

#pragma mark - App row

@interface SNAppRow : NSView
@property(nonatomic, copy) NSString *key;
@end

@implementation SNAppRow {
    NSButton *_iconButton;
    NSTextField *_name, *_percent;
    NSSlider *_slider;
    BOOL _muted, _inCall;
}

- (instancetype)initWithApp:(SNApp *)app {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, kRowWidth, kRowHeight)])) return nil;
    _key = app.key;
    SNEngine *engine = [SNEngine shared];
    _muted = [engine mutedForKey:app.key];
    _inCall = app.inCall;

    _iconButton = [NSButton buttonWithImage:app.icon target:self action:@selector(toggleMute:)];
    _iconButton.frame = NSMakeRect(14, 6, 28, 28);
    _iconButton.bordered = NO;
    _iconButton.imageScaling = NSImageScaleProportionallyUpOrDown;
    _iconButton.toolTip = @"Click to mute or unmute";
    [self addSubview:_iconButton];

    _name = [NSTextField labelWithString:app.name ?: app.key];
    _name.frame = NSMakeRect(50, 22, 180, 15);
    _name.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    _name.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_name];

    _slider = [NSSlider sliderWithValue:[engine volumeForKey:app.key] minValue:0 maxValue:kMaxVolume
                                 target:self action:@selector(sliderMoved:)];
    _slider.frame = NSMakeRect(48, 3, 196, 20);
    _slider.controlSize = NSControlSizeSmall;
    _slider.continuous = YES;
    [self addSubview:_slider];

    _percent = [NSTextField labelWithString:@""];
    _percent.frame = NSMakeRect(246, 6, 46, 15);
    _percent.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    _percent.alignment = NSTextAlignmentRight;
    [self addSubview:_percent];

    [self updateLabels];
    return self;
}

- (void)updateLabels {
    if (_inCall) {
        // A tap sees call audio far below its final level, so it can't be scaled
        // accurately. Leave it to the system volume.
        _slider.doubleValue = 100;
        _slider.enabled = NO;
        _iconButton.enabled = NO;
        _iconButton.toolTip = @"This app is in a call. Use the system volume for it, and lower the other apps here.";
        _percent.stringValue = @"In call";
        _percent.textColor = NSColor.secondaryLabelColor;
        return;
    }
    _percent.stringValue = _muted ? @"Muted" : [NSString stringWithFormat:@"%d%%", (int)lround(_slider.doubleValue)];
    _percent.textColor = _muted ? NSColor.secondaryLabelColor : NSColor.labelColor;
    _iconButton.alphaValue = _muted ? 0.35 : 1.0;
    _slider.enabled = !_muted;
}

- (void)sliderMoved:(NSSlider *)slider {
    double v = round(slider.doubleValue);
    if (fabs(v - 100) < 3) v = 100; // snap to the "untouched" level
    slider.doubleValue = v;
    [self updateLabels];
    [[SNEngine shared] setVolume:v muted:_muted forKey:_key];
}

- (void)toggleMute:(id)sender {
    _muted = !_muted;
    [self updateLabels];
    [[SNEngine shared] setVolume:round(_slider.doubleValue) muted:_muted forKey:_key];
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
    NSImage *image = [NSImage imageWithSystemSymbolName:@"slider.vertical.3" accessibilityDescription:@"Sonora"];
    image.template = YES;
    _statusItem.button.image = image;
    _statusItem.button.toolTip = @"Sonora — per-app volume";

    _menu = [NSMenu new];
    _menu.delegate = self;
    _menu.autoenablesItems = NO;
    _statusItem.menu = _menu;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appsChanged:)
                                                 name:SNEngineAppsDidChangeNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(volumeChanged:)
                                                 name:SNEngineVolumeDidChangeNotification object:nil];
    [[SNEngine shared] start];
    [self announce:@"SONORA"];
}

- (void)applicationWillTerminate:(NSNotification *)note {
    [[SNEngine shared] shutdown];
}

- (void)menuNeedsUpdate:(NSMenu *)menu { [self rebuildMenu]; }
- (void)menuWillOpen:(NSMenu *)menu { _menuOpen = YES; }
- (void)menuDidClose:(NSMenu *)menu { _menuOpen = NO; }

- (void)appsChanged:(NSNotification *)note {
    if (_menuOpen) [self rebuildMenu]; // an app started or stopped while the menu is showing
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

    if (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) {
        [self setTitleText:text];
    } else if (!_scrambleTimer) {
        __weak SNAppDelegate *weakSelf = self;
        _scrambleTimer = [NSTimer scheduledTimerWithTimeInterval:0.035 repeats:YES block:^(NSTimer *t) { [weakSelf tick]; }];
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
    _clearTimer = [NSTimer scheduledTimerWithTimeInterval:2.5 repeats:NO block:^(NSTimer *t) {
        SNAppDelegate *strongSelf = weakSelf;
        [strongSelf setTitleText:@""];
        strongSelf->_clearTimer = nil;
    }];
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

- (NSMenuItem *)header:(NSString *)title {
    NSMenuItem *item = [NSMenuItem sectionHeaderWithTitle:title];
    return item;
}

- (void)rebuildMenu {
    [_menu removeAllItems];
    SNEngine *engine = [SNEngine shared];

    NSString *output = engine.outputDeviceName;
    [_menu addItem:[self header:output ? [@"Output: " stringByAppendingString:output] : @"Sonora"]];

    if (engine.apps.count == 0) {
        NSMenuItem *empty = [[NSMenuItem alloc] initWithTitle:@"No apps are playing audio" action:nil keyEquivalent:@""];
        empty.enabled = NO;
        [_menu addItem:empty];
    }
    for (SNApp *app in engine.apps) {
        NSMenuItem *item = [NSMenuItem new];
        item.view = [[SNAppRow alloc] initWithApp:app];
        [_menu addItem:item];
    }

    [_menu addItem:NSMenuItem.separatorItem];
    [self addItem:@"Reset All to 100%" action:@selector(resetAll:) key:@""];

    NSMenuItem *login = [self addItem:@"Launch at Login" action:@selector(toggleLogin:) key:@""];
    login.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;

    [self addItem:@"Sonora on GitHub" action:@selector(openGitHub:) key:@""];
    [_menu addItem:NSMenuItem.separatorItem];
    [self addItem:@"Quit Sonora" action:@selector(quit:) key:@"q"];
}

- (NSMenuItem *)addItem:(NSString *)title action:(SEL)action key:(NSString *)key {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
    item.target = self;
    [_menu addItem:item];
    return item;
}

- (void)resetAll:(id)sender { [[SNEngine shared] resetAll]; }

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
