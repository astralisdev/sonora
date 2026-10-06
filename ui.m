// ui.m — the menu bar item and its per-app volume sliders.

#import <AppKit/AppKit.h>
#import <ServiceManagement/ServiceManagement.h>
#import "engine.h"
#include "tapmix.h"

static const CGFloat kRowWidth = 300, kRowHeight = 40, kMaxVolume = 150;

#pragma mark - App row

@interface TMAppRow : NSView
@property(nonatomic, copy) NSString *key;
@end

@implementation TMAppRow {
    NSButton *_iconButton;
    NSTextField *_name, *_percent;
    NSSlider *_slider;
    BOOL _muted;
}

- (instancetype)initWithApp:(TMApp *)app {
    if (!(self = [super initWithFrame:NSMakeRect(0, 0, kRowWidth, kRowHeight)])) return nil;
    _key = app.key;
    TMEngine *engine = [TMEngine shared];
    _muted = [engine mutedForKey:app.key];

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
    _slider.frame = NSMakeRect(48, 3, 200, 20);
    _slider.controlSize = NSControlSizeSmall;
    _slider.continuous = YES;
    [self addSubview:_slider];

    _percent = [NSTextField labelWithString:@""];
    _percent.frame = NSMakeRect(250, 6, 40, 15);
    _percent.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    _percent.alignment = NSTextAlignmentRight;
    [self addSubview:_percent];

    [self updateLabels];
    return self;
}

- (void)updateLabels {
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
    [[TMEngine shared] setVolume:v muted:_muted forKey:_key];
}

- (void)toggleMute:(id)sender {
    _muted = !_muted;
    [self updateLabels];
    [[TMEngine shared] setVolume:round(_slider.doubleValue) muted:_muted forKey:_key];
}
@end

#pragma mark - App delegate

@interface TMAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@end

@implementation TMAppDelegate {
    NSStatusItem *_statusItem;
    NSMenu *_menu;
    BOOL _menuOpen;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    _statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    NSImage *image = [NSImage imageWithSystemSymbolName:@"slider.vertical.3" accessibilityDescription:@"Tapmix"];
    image.template = YES;
    _statusItem.button.image = image;
    _statusItem.button.toolTip = @"Tapmix — per-app volume";

    _menu = [NSMenu new];
    _menu.delegate = self;
    _menu.autoenablesItems = NO;
    _statusItem.menu = _menu;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(appsChanged:)
                                                 name:TMEngineAppsDidChangeNotification object:nil];
    [[TMEngine shared] start];
}

- (void)applicationWillTerminate:(NSNotification *)note {
    [[TMEngine shared] shutdown];
}

- (void)menuNeedsUpdate:(NSMenu *)menu { [self rebuildMenu]; }
- (void)menuWillOpen:(NSMenu *)menu { _menuOpen = YES; }
- (void)menuDidClose:(NSMenu *)menu { _menuOpen = NO; }

- (void)appsChanged:(NSNotification *)note {
    if (_menuOpen) [self rebuildMenu]; // an app started or stopped while the menu is showing
}

- (NSMenuItem *)header:(NSString *)title {
    NSMenuItem *item = [NSMenuItem sectionHeaderWithTitle:title];
    return item;
}

- (void)rebuildMenu {
    [_menu removeAllItems];
    TMEngine *engine = [TMEngine shared];

    NSString *output = engine.outputDeviceName;
    [_menu addItem:[self header:output ? [@"Output: " stringByAppendingString:output] : @"Tapmix"]];

    if (engine.apps.count == 0) {
        NSMenuItem *empty = [[NSMenuItem alloc] initWithTitle:@"No apps are playing audio" action:nil keyEquivalent:@""];
        empty.enabled = NO;
        [_menu addItem:empty];
    }
    for (TMApp *app in engine.apps) {
        NSMenuItem *item = [NSMenuItem new];
        item.view = [[TMAppRow alloc] initWithApp:app];
        [_menu addItem:item];
    }

    [_menu addItem:NSMenuItem.separatorItem];
    [self addItem:@"Reset All to 100%" action:@selector(resetAll:) key:@""];

    NSMenuItem *login = [self addItem:@"Launch at Login" action:@selector(toggleLogin:) key:@""];
    login.state = SMAppService.mainAppService.status == SMAppServiceStatusEnabled ? NSControlStateValueOn : NSControlStateValueOff;

    [self addItem:@"Tapmix on GitHub" action:@selector(openGitHub:) key:@""];
    [_menu addItem:NSMenuItem.separatorItem];
    [self addItem:@"Quit Tapmix" action:@selector(quit:) key:@"q"];
}

- (NSMenuItem *)addItem:(NSString *)title action:(SEL)action key:(NSString *)key {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
    item.target = self;
    [_menu addItem:item];
    return item;
}

- (void)resetAll:(id)sender { [[TMEngine shared] resetAll]; }

- (void)toggleLogin:(id)sender {
    SMAppService *svc = SMAppService.mainAppService;
    NSError *err = nil;
    BOOL ok = svc.status == SMAppServiceStatusEnabled ? [svc unregisterAndReturnError:&err] : [svc registerAndReturnError:&err];
    if (!ok) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Couldn't change the login item";
        alert.informativeText = err.localizedDescription ?: @"Move Tapmix to /Applications and try again.";
        [NSApp activateIgnoringOtherApps:YES];
        [alert runModal];
    }
}

- (void)openGitHub:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://github.com/astralisdev/tapmix"]];
}

- (void)quit:(id)sender { [NSApp terminate:nil]; }
@end

void TMRun(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyAccessory; // menu bar only, no Dock icon
        static TMAppDelegate *delegate;
        delegate = [TMAppDelegate new];
        app.delegate = delegate;
        [app run];
    }
}
