// engine.h — Objective-C interface of the per-app audio engine.
#import <AppKit/AppKit.h>
#import <CoreAudio/CoreAudio.h>

extern NSNotificationName const SNEngineAppsDidChangeNotification;
// Posted when the user changes an app's volume or mute. userInfo: key, percent (NSNumber), muted (NSNumber).
extern NSNotificationName const SNEngineVolumeDidChangeNotification;
// Posted when permissionProblem changes.
extern NSNotificationName const SNEnginePermissionDidChangeNotification;
// Posted when an app starts or ends a call. userInfo: key, name.
extern NSNotificationName const SNEngineCallDidStartNotification;
extern NSNotificationName const SNEngineCallDidEndNotification;

// One user-facing app, possibly made of several audio processes (e.g. a browser
// and its helper processes all count as the browser).
@interface SNApp : NSObject
@property(nonatomic, copy) NSString *key;      // bundle ID, or "pid:<n>" fallback
@property(nonatomic, copy) NSString *name;
@property(nonatomic, strong) NSImage *icon;
@property(nonatomic, copy) NSArray<NSNumber *> *processObjects; // AudioObjectIDs
@property(nonatomic) BOOL playing;             // any process is producing output
@property(nonatomic) BOOL listening;           // some process is using the microphone
@property(nonatomic) BOOL voiceProcessing;     // some process runs Apple voice processing
@property(nonatomic) BOOL inCall;              // in a call (see SNEngine refresh)
@property(nonatomic) BOOL isSystem;            // background/system process rather than a regular app
// Where this app's volume is stored. Calls have their own volume
// ("<bundle id>@call"), so turning a call up doesn't make the app's
// notifications and videos loud once the call is over.
@property(nonatomic, readonly) NSString *settingsKey;
@end

// System Audio Recording permission as macOS reports it.
typedef NS_ENUM(int, SNPermission) {
    SNPermissionUnknown = -1, // macOS gave no answer (private API missing)
    SNPermissionGranted = 0,
    SNPermissionDenied = 1,
    SNPermissionNotAsked = 2,
};

@interface SNEngine : NSObject
+ (instancetype)shared;
- (void)start;

// Regular apps that are playing audio, or did recently. Main thread only.
@property(nonatomic, readonly) NSArray<SNApp *> *apps;
@property(nonatomic, readonly) NSString *outputDeviceName;

// YES when Sonora can't capture app audio (System Audio Recording permission
// denied, or taps only ever deliver silence). Sonora then stops tapping so no
// app is left muted.
@property(nonatomic, readonly) BOOL permissionProblem;
- (void)retryPermission;

@property(nonatomic, readonly) SNPermission permission;
// Makes macOS show its System Audio Recording prompt now, by briefly reading
// a listen-only tap, instead of when the user first moves a slider.
- (void)requestPermission;

// YES while an app is in a call (running Apple voice processing).
@property(nonatomic, readonly) BOOL callActive;

// Voice leveling for calls: keeps everyone in a call at the same loudness.
// Off by default: it has to replay the call, which can be quieter than the
// call app's own sound. Persisted as evenOutVoices.
@property(nonatomic) BOOL evenOutVoices;

// How much other apps are lowered while a call is active: 0 = off, 6 or 12 dB,
// 100 = muted. Persisted in settings.json as callDuckDB.
@property(nonatomic) double callDuckDB;

- (double)volumeForKey:(NSString *)key;   // percent, 0–100 (100 = the app's own level)
- (BOOL)mutedForKey:(NSString *)key;
- (void)setVolume:(double)percent muted:(BOOL)muted forKey:(NSString *)key;
- (void)resetAll;
- (void)shutdown; // tears down every tap so apps are never left muted

+ (NSArray<SNApp *> *)scanApps; // fresh snapshot of Core Audio's process list
@end
