// engine.h — Objective-C interface of the per-app audio engine.
#import <AppKit/AppKit.h>
#import <CoreAudio/CoreAudio.h>

extern NSNotificationName const TMEngineAppsDidChangeNotification;

// One user-facing app, possibly made of several audio processes (e.g. a browser
// and its helper processes all count as the browser).
@interface TMApp : NSObject
@property(nonatomic, copy) NSString *key;      // bundle ID, or "pid:<n>" fallback
@property(nonatomic, copy) NSString *name;
@property(nonatomic, strong) NSImage *icon;
@property(nonatomic, copy) NSArray<NSNumber *> *processObjects; // AudioObjectIDs
@property(nonatomic) BOOL playing;             // any process is producing output
@end

@interface TMEngine : NSObject
+ (instancetype)shared;
- (void)start;

// Apps that are playing audio right now, or were tapped recently. Main thread only.
@property(nonatomic, readonly) NSArray<TMApp *> *apps;
@property(nonatomic, readonly) NSString *outputDeviceName;

- (double)volumeForKey:(NSString *)key;   // percent, 0–150
- (BOOL)mutedForKey:(NSString *)key;
- (void)setVolume:(double)percent muted:(BOOL)muted forKey:(NSString *)key;
- (void)resetAll;
- (void)shutdown; // tears down every tap so apps are never left muted

+ (NSArray<TMApp *> *)scanApps; // fresh snapshot of Core Audio's process list
@end
