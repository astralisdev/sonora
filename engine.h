// engine.h — Objective-C interface of the per-app audio engine.
#import <AppKit/AppKit.h>
#import <CoreAudio/CoreAudio.h>

extern NSNotificationName const SNEngineAppsDidChangeNotification;
// Posted when the user changes an app's volume or mute. userInfo: key, percent (NSNumber), muted (NSNumber).
extern NSNotificationName const SNEngineVolumeDidChangeNotification;
// Posted when permissionProblem changes.
extern NSNotificationName const SNEnginePermissionDidChangeNotification;

// One user-facing app, possibly made of several audio processes (e.g. a browser
// and its helper processes all count as the browser).
@interface SNApp : NSObject
@property(nonatomic, copy) NSString *key;      // bundle ID, or "pid:<n>" fallback
@property(nonatomic, copy) NSString *name;
@property(nonatomic, strong) NSImage *icon;
@property(nonatomic, copy) NSArray<NSNumber *> *processObjects; // AudioObjectIDs
@property(nonatomic) BOOL playing;             // any process is producing output
@property(nonatomic) BOOL inCall;              // running Apple voice processing (a call)
@property(nonatomic) BOOL isSystem;            // background/system process rather than a regular app
@end

@interface SNEngine : NSObject
+ (instancetype)shared;
- (void)start;

// Apps that are playing audio right now, or were tapped recently. Main thread only.
@property(nonatomic, readonly) NSArray<SNApp *> *apps;
@property(nonatomic, readonly) NSString *outputDeviceName;

// YES when Sonora can't capture app audio (System Audio Recording permission
// denied, or taps only ever deliver silence). Sonora then stops tapping so no
// app is left muted.
@property(nonatomic, readonly) BOOL permissionProblem;
- (void)retryPermission;

- (double)volumeForKey:(NSString *)key;   // percent, 0–150
- (BOOL)mutedForKey:(NSString *)key;
- (void)setVolume:(double)percent muted:(BOOL)muted forKey:(NSString *)key;
- (void)resetAll;
- (void)shutdown; // tears down every tap so apps are never left muted

+ (NSArray<SNApp *> *)scanApps; // fresh snapshot of Core Audio's process list
@end
