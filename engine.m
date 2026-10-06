// engine.m — per-app volume using Core Audio process taps (macOS 14.2+).
//
// For every app whose volume is not 100%, Sonora creates:
//   1. a private process tap over all of the app's audio processes, which
//      mutes the app's own output while Sonora is reading from it, and
//   2. a private aggregate device made of the current output device plus
//      that tap, whose IOProc copies the tapped audio to the output scaled
//      by the app's gain.
// Apps at 100% are left untouched, so Sonora adds no latency to them.

#import "engine.h"
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#include <dlfcn.h>
#include <libproc.h>
#include <stdatomic.h>
#include "_cgo_export.h"

NSNotificationName const SNEngineAppsDidChangeNotification = @"SNEngineAppsDidChange";
NSNotificationName const SNEngineVolumeDidChangeNotification = @"SNEngineVolumeDidChange";

// How long a tap is kept after its app goes quiet, so pausing and resuming a
// video doesn't rebuild the tap every time.
static const NSTimeInterval kTapGracePeriod = 8.0;

#pragma mark - Core Audio helpers

static AudioObjectPropertyAddress addr(AudioObjectPropertySelector sel, AudioObjectPropertyScope scope) {
    return (AudioObjectPropertyAddress){sel, scope, kAudioObjectPropertyElementMain};
}

static UInt32 readU32(AudioObjectID obj, AudioObjectPropertySelector sel, UInt32 fallback) {
    AudioObjectPropertyAddress a = addr(sel, kAudioObjectPropertyScopeGlobal);
    UInt32 v = 0, size = sizeof(v);
    return AudioObjectGetPropertyData(obj, &a, 0, NULL, &size, &v) == noErr ? v : fallback;
}

static NSString *readString(AudioObjectID obj, AudioObjectPropertySelector sel) {
    AudioObjectPropertyAddress a = addr(sel, kAudioObjectPropertyScopeGlobal);
    CFStringRef s = NULL;
    UInt32 size = sizeof(s);
    if (AudioObjectGetPropertyData(obj, &a, 0, NULL, &size, &s) != noErr || s == NULL) return nil;
    NSString *str = (__bridge_transfer NSString *)s;
    return str.length ? str : nil;
}

static NSArray<NSNumber *> *readObjectList(AudioObjectID obj, AudioObjectPropertySelector sel) {
    AudioObjectPropertyAddress a = addr(sel, kAudioObjectPropertyScopeGlobal);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(obj, &a, 0, NULL, &size) != noErr || size == 0) return @[];
    UInt32 count = size / sizeof(AudioObjectID);
    AudioObjectID *ids = calloc(count, sizeof(AudioObjectID));
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:count];
    if (AudioObjectGetPropertyData(obj, &a, 0, NULL, &size, ids) == noErr) {
        for (UInt32 i = 0; i < size / sizeof(AudioObjectID); i++) [out addObject:@(ids[i])];
    }
    free(ids);
    return out;
}

static AudioObjectID defaultOutputDevice(void) {
    return readU32(kAudioObjectSystemObject, kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectUnknown);
}

// The process macOS holds responsible for `pid` — e.g. Chrome for a
// "Google Chrome Helper", Safari for a WebKit WebContent process. This is a
// private libsystem symbol, so it's looked up at runtime and optional.
static pid_t responsiblePID(pid_t pid) {
    static pid_t (*fn)(pid_t);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fn = dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid"); });
    if (fn) {
        pid_t r = fn(pid);
        if (r > 0) return r;
    }
    return pid;
}

// For helpers and extensions such as "net.whatsapp.WhatsApp.ServiceExtension",
// finds the running app whose bundle ID is a prefix of theirs.
static NSRunningApplication *owningApp(NSString *bundleID) {
    NSArray<NSString *> *parts = [bundleID componentsSeparatedByString:@"."];
    for (NSInteger n = (NSInteger)parts.count - 1; n >= 2; n--) {
        NSString *prefix = [[parts subarrayWithRange:NSMakeRange(0, n)] componentsJoinedByString:@"."];
        for (NSRunningApplication *ra in [NSRunningApplication runningApplicationsWithBundleIdentifier:prefix]) {
            if (ra.activationPolicy == NSApplicationActivationPolicyRegular) return ra;
        }
    }
    return nil;
}

// Slider percent → linear gain. Below 100% it follows a squared curve (50% is
// about -12 dB, which sounds close to half as loud). Above 100% it boosts in
// even dB steps up to +6 dB at 150%, so the top of the slider isn't a cliff.
static float gainFor(double percent, BOOL muted) {
    if (muted) return 0;
    if (percent <= 100) {
        double x = percent / 100.0;
        return (float)(x * x);
    }
    return (float)pow(10.0, (percent - 100.0) / 50.0 * 6.0 / 20.0);
}

#pragma mark - Model

@implementation SNApp
@end

#pragma mark - Real-time render

typedef struct {
    _Atomic float target;
    float current;
    UInt32 tapBuffers; // the tap's buffers are the last ones in the input list
    // Level meters, only touched when gDiag is set (debug aid, racy on purpose).
    double inSq, outSq;
    uint64_t cnt;
    float inPeak, outPeak;
} SNRender;


static BOOL gDiag;
static double dB(double x) { return x > 1e-9 ? 20 * log10(x) : -999; }

enum { kMaxChannels = 16 };


// Collects the tap's channels from the input list (they're the last buffers).
static UInt32 gatherSource(const SNRender *r, const AudioBufferList *in, const float **src, UInt32 *srcStride,
                           UInt32 *framesOut) {
    UInt32 nsrc = 0, frames = UINT32_MAX;
    if (in && in->mNumberBuffers >= r->tapBuffers) {
        for (UInt32 b = in->mNumberBuffers - r->tapBuffers; b < in->mNumberBuffers; b++) {
            const AudioBuffer *ab = &in->mBuffers[b];
            if (!ab->mData || ab->mNumberChannels == 0) continue;
            UInt32 f = ab->mDataByteSize / (UInt32)(sizeof(float) * ab->mNumberChannels);
            if (f < frames) frames = f;
            for (UInt32 c = 0; c < ab->mNumberChannels && nsrc < kMaxChannels; c++, nsrc++) {
                src[nsrc] = (const float *)ab->mData + c;
                srcStride[nsrc] = ab->mNumberChannels;
            }
        }
    }
    *framesOut = nsrc ? frames : 0;
    return nsrc;
}

// Runs on Core Audio's real-time thread: no locks, no allocation, no ObjC.
// Transparent below 0.8, then a smooth knee that approaches ±1 instead of
// hard-clipping boosted peaks.
static inline float softLimit(float v) {
    const float t = 0.8f;
    float a = fabsf(v);
    if (a <= t) return v;
    float y = t + (1.f - t) * tanhf((a - t) / (1.f - t));
    return v < 0 ? -y : y;
}

static void render(SNRender *r, const AudioBufferList *in, AudioBufferList *out) {
    float target = atomic_load_explicit(&r->target, memory_order_relaxed);

    const float *src[kMaxChannels];
    UInt32 srcStride[kMaxChannels], frames;
    UInt32 nsrc = gatherSource(r, in, src, srcStride, &frames);

    // Ramp from the previous gain to avoid clicks while a slider moves.
    float start = r->current;
    UInt32 oc = 0;
    for (UInt32 b = 0; b < out->mNumberBuffers; b++) {
        AudioBuffer *ab = &out->mBuffers[b];
        if (!ab->mData) continue;
        memset(ab->mData, 0, ab->mDataByteSize);
        UInt32 n = ab->mNumberChannels;
        if (n == 0) continue;
        UInt32 outFrames = ab->mDataByteSize / (UInt32)(sizeof(float) * n);
        UInt32 fr = frames < outFrames ? frames : outFrames;
        float step = fr ? (target - start) / (float)fr : 0;
        for (UInt32 c = 0; c < n; c++, oc++) {
            int si = oc < nsrc ? (int)oc : (nsrc == 1 && oc < 2 ? 0 : -1); // mono → both sides
            if (si < 0) continue;
            float *dst = (float *)ab->mData + c;
            const float *s = src[si];
            UInt32 ss = srcStride[si];
            float g = start;
            for (UInt32 i = 0; i < fr; i++, g += step) {
                float x = s[i * ss];
                float v = x * g;
                float y = softLimit(v);
                dst[i * n] = y;
                if (gDiag) {
                    r->cnt++;
                    r->inSq += x * x; r->outSq += y * y;
                    if (fabsf(x) > r->inPeak) r->inPeak = fabsf(x);
                    if (fabsf(y) > r->outPeak) r->outPeak = fabsf(y);
                }
            }
        }
    }
    r->current = target;
}

#pragma mark - Tap

// One live tap + aggregate device. Created and destroyed only on the engine's tap queue.
@interface SNTap : NSObject
@property(nonatomic, copy) NSArray<NSNumber *> *processes;
@property(nonatomic, copy) NSString *outputUID;
@property(nonatomic) SNRender *render;
@end

@implementation SNTap {
    AudioObjectID _tapID, _aggID;
    AudioDeviceIOProcID _procID;
}

- (instancetype)initWithKey:(NSString *)key processes:(NSArray<NSNumber *> *)processes
                  outputUID:(NSString *)outputUID gain:(float)gain {
    if (!(self = [super init])) return nil;
    _processes = [processes copy];
    _outputUID = [outputUID copy];
    _render = calloc(1, sizeof(SNRender));
    atomic_store(&_render->target, gain);
    _render->current = gain;
    _render->tapBuffers = 1;

    CATapDescription *desc = [[CATapDescription alloc] initStereoMixdownOfProcesses:processes];
    desc.name = [@"Sonora " stringByAppendingString:key];
    desc.privateTap = YES;
    // Muted only while Sonora reads the tap: if Sonora stops or crashes the
    // app is audible again rather than silenced.
    desc.muteBehavior = CATapMutedWhenTapped;

    OSStatus err = AudioHardwareCreateProcessTap(desc, &_tapID);
    if (err != noErr) {
        NSLog(@"sonora: creating tap for %@ failed (%d)", key, (int)err);
        [self teardown];
        return nil;
    }

    AudioObjectPropertyAddress fa = addr(kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal);
    AudioStreamBasicDescription fmt = {0};
    UInt32 size = sizeof(fmt);
    if (AudioObjectGetPropertyData(_tapID, &fa, 0, NULL, &size, &fmt) == noErr &&
        (fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved) && fmt.mChannelsPerFrame > 0) {
        _render->tapBuffers = fmt.mChannelsPerFrame;
    }

    NSDictionary *agg = @{
        @kAudioAggregateDeviceNameKey : [@"Sonora " stringByAppendingString:key],
        @kAudioAggregateDeviceUIDKey : [@"sonora-" stringByAppendingString:[NSUUID UUID].UUIDString],
        @kAudioAggregateDeviceMainSubDeviceKey : outputUID,
        @kAudioAggregateDeviceIsPrivateKey : @YES,
        @kAudioAggregateDeviceIsStackedKey : @NO,
        @kAudioAggregateDeviceTapAutoStartKey : @YES,
        @kAudioAggregateDeviceSubDeviceListKey : @[ @{@kAudioSubDeviceUIDKey : outputUID} ],
        @kAudioAggregateDeviceTapListKey : @[ @{
            @kAudioSubTapUIDKey : desc.UUID.UUIDString,
            @kAudioSubTapDriftCompensationKey : @YES,
        } ],
    };
    err = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)agg, &_aggID);
    if (err != noErr) {
        NSLog(@"sonora: creating aggregate device for %@ failed (%d)", key, (int)err);
        [self teardown];
        return nil;
    }

    SNRender *r = _render;
    err = AudioDeviceCreateIOProcIDWithBlock(&_procID, _aggID, NULL,
        ^(const AudioTimeStamp *now, const AudioBufferList *inData, const AudioTimeStamp *inTime,
          AudioBufferList *outData, const AudioTimeStamp *outTime) {
            render(r, inData, outData);
        });
    if (err == noErr) err = AudioDeviceStart(_aggID, _procID);
    if (err != noErr) {
        NSLog(@"sonora: starting audio for %@ failed (%d)", key, (int)err);
        [self teardown];
        return nil;
    }
    return self;
}

// Debug: levels since the last call, as "in/out rms dB, peak dB, gain".
- (NSString *)takeStats {
    SNRender *r = _render;
    if (!r) return @"(gone)";
    double n = r->cnt ? (double)r->cnt : 1;
    NSString *s = [NSString stringWithFormat:@"in rms %6.1f peak %6.1f | out rms %6.1f peak %6.1f dB | gain target %.3f current %.3f",
                   dB(sqrt(r->inSq / n)), dB(r->inPeak), dB(sqrt(r->outSq / n)), dB(r->outPeak),
                   atomic_load(&r->target), r->current];
    r->inSq = r->outSq = 0; r->inPeak = r->outPeak = 0; r->cnt = 0;
    return s;
}

- (void)setGain:(float)gain {
    atomic_store_explicit(&_render->target, gain, memory_order_relaxed);
}

- (void)teardown {
    if (_procID) {
        AudioDeviceStop(_aggID, _procID);
        AudioDeviceDestroyIOProcID(_aggID, _procID); // waits for any running callback
        _procID = NULL;
    }
    if (_aggID) {
        AudioHardwareDestroyAggregateDevice(_aggID);
        _aggID = 0;
    }
    if (_tapID) {
        AudioHardwareDestroyProcessTap(_tapID);
        _tapID = 0;
    }
    free(_render);
    _render = NULL;
}

- (void)dealloc {
    [self teardown];
}
@end

#pragma mark - Engine

@implementation SNEngine {
    dispatch_queue_t _tapQueue;
    NSMutableDictionary<NSString *, SNTap *> *_taps;          // tap queue only
    NSMutableDictionary<NSString *, NSDate *> *_lastPlaying;  // main thread only
    NSMutableSet<NSNumber *> *_observedProcesses;             // main thread only
    NSArray<SNApp *> *_apps;
    NSString *_outputDeviceName;
    NSString *_outputUID;
    NSTimer *_timer;
}

+ (instancetype)shared {
    static SNEngine *engine;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ engine = [SNEngine new]; });
    return engine;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _tapQueue = dispatch_queue_create("sonora.taps", DISPATCH_QUEUE_SERIAL);
    _taps = [NSMutableDictionary new];
    _lastPlaying = [NSMutableDictionary new];
    _observedProcesses = [NSMutableSet new];
    _apps = @[];
    return self;
}

- (NSArray<SNApp *> *)apps { return _apps; }
- (NSString *)outputDeviceName { return _outputDeviceName; }

- (void)start {
    __weak SNEngine *weakSelf = self;
    if (getenv("SONORA_DEBUG")) {
        gDiag = YES;
        [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) {
            SNEngine *e = weakSelf;
            dispatch_async(e->_tapQueue, ^{
                for (NSString *key in e->_taps) NSLog(@"sonora[debug] %@: %@", key, [e->_taps[key] takeStats]);
            });
        }];
    }
    AudioObjectPropertyListenerBlock refresh = ^(UInt32 n, const AudioObjectPropertyAddress *a) {
        [weakSelf refresh];
    };
    AudioObjectPropertyAddress procs = addr(kAudioHardwarePropertyProcessObjectList, kAudioObjectPropertyScopeGlobal);
    AudioObjectPropertyAddress dev = addr(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal);
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &procs, dispatch_get_main_queue(), refresh);
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &dev, dispatch_get_main_queue(), refresh);

    // Listeners cover starts/stops; the timer handles the grace-period expiry.
    _timer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) { [weakSelf refresh]; }];
    _timer.tolerance = 0.5;
    [self refresh];
}

+ (NSArray<SNApp *> *)scanApps {
    pid_t me = getpid();
    NSMutableDictionary<NSString *, SNApp *> *byKey = [NSMutableDictionary new];
    NSMutableArray<SNApp *> *ordered = [NSMutableArray new];

    for (NSNumber *obj in readObjectList(kAudioObjectSystemObject, kAudioHardwarePropertyProcessObjectList)) {
        AudioObjectID pobj = obj.unsignedIntValue;
        pid_t pid = (pid_t)readU32(pobj, kAudioProcessPropertyPID, 0);
        if (pid <= 0 || pid == me) continue;
        NSString *bundleID = readString(pobj, kAudioProcessPropertyBundleID);
        BOOL playing = readU32(pobj, kAudioProcessPropertyIsRunningOutput, 0) != 0;
        BOOL listening = readU32(pobj, kAudioProcessPropertyIsRunningInput, 0) != 0;

        NSRunningApplication *ra = [NSRunningApplication runningApplicationWithProcessIdentifier:responsiblePID(pid)];
        if (!ra.bundleIdentifier) ra = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        if (!ra || ra.activationPolicy != NSApplicationActivationPolicyRegular) {
            ra = owningApp(ra.bundleIdentifier ?: bundleID) ?: ra;
        }
        NSString *key = ra.bundleIdentifier ?: bundleID ?: [NSString stringWithFormat:@"pid:%d", pid];

        SNApp *app = byKey[key];
        if (!app) {
            app = [SNApp new];
            app.key = key;
            app.processObjects = @[];
            app.name = [ra.localizedName stringByTrimmingCharactersInSet:NSCharacterSet.controlCharacterSet];
            if (!app.name) {
                char buf[2 * MAXCOMLEN] = {0};
                proc_name(pid, buf, sizeof(buf));
                app.name = buf[0] ? @(buf) : (bundleID ?: key);
            }
            app.icon = ra.icon ?: [NSImage imageWithSystemSymbolName:@"app.dashed" accessibilityDescription:nil];
            byKey[key] = app;
            [ordered addObject:app];
        }
        app.processObjects = [app.processObjects arrayByAddingObject:obj];
        app.playing = app.playing || playing;
        app.inCall = app.inCall || (playing && listening);
    }
    return ordered;
}

- (void)refresh {
    NSArray<SNApp *> *scanned = [SNEngine scanApps];

    // Watch each process's "is running output" flag so play/pause is noticed immediately.
    __weak SNEngine *weakSelf = self;
    NSMutableSet *current = [NSMutableSet new];
    for (SNApp *app in scanned) {
        for (NSNumber *obj in app.processObjects) {
            [current addObject:obj];
            if ([_observedProcesses containsObject:obj]) continue;
            AudioObjectPropertyAddress a = addr(kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal);
            AudioObjectAddPropertyListenerBlock(obj.unsignedIntValue, &a, dispatch_get_main_queue(),
                ^(UInt32 n, const AudioObjectPropertyAddress *x) { [weakSelf refresh]; });
        }
    }
    [_observedProcesses setSet:current]; // dead process objects take their listeners with them

    NSDate *now = [NSDate date];
    NSMutableArray<SNApp *> *visible = [NSMutableArray new];
    for (SNApp *app in scanned) {
        if (app.playing) _lastPlaying[app.key] = now;
        NSDate *last = _lastPlaying[app.key];
        if (last && [now timeIntervalSinceDate:last] < kTapGracePeriod) [visible addObject:app];
    }
    [visible sortUsingComparator:^NSComparisonResult(SNApp *a, SNApp *b) {
        return [a.name localizedCaseInsensitiveCompare:b.name];
    }];

    AudioObjectID dev = defaultOutputDevice();
    _outputUID = readString(dev, kAudioDevicePropertyDeviceUID);
    _outputDeviceName = readString(dev, kAudioObjectPropertyName);

    NSString *(^signature)(NSArray<SNApp *> *) = ^NSString *(NSArray<SNApp *> *list) {
        NSMutableString *sig = [NSMutableString new];
        for (SNApp *a in list) [sig appendFormat:@"%@:%d;", a.key, a.inCall];
        return sig;
    };
    BOOL changed = ![signature(_apps) isEqualToString:signature(visible)];
    _apps = visible;
    [self apply];
    if (changed) [[NSNotificationCenter defaultCenter] postNotificationName:SNEngineAppsDidChangeNotification object:self];
}

// Pushes the current settings for the visible apps to the tap queue. Cheap
// enough to call on every slider tick.
- (void)apply {
    NSMutableDictionary<NSString *, NSDictionary *> *wanted = [NSMutableDictionary new];
    for (SNApp *app in _apps) {
        if (app.inCall) continue; // call audio reaches a tap far below its final level; leave it alone
        float gain = gainFor([self volumeForKey:app.key], [self mutedForKey:app.key]);
        if (gain != 1.f) wanted[app.key] = @{@"processes" : app.processObjects, @"gain" : @(gain)};
    }
    [self reconcile:wanted outputUID:_outputUID];
}

// Makes the set of live taps match `wanted` (key → processes + gain).
- (void)reconcile:(NSDictionary<NSString *, NSDictionary *> *)wanted outputUID:(NSString *)outputUID {
    dispatch_async(_tapQueue, ^{
        for (NSString *key in self->_taps.allKeys) {
            SNTap *tap = self->_taps[key];
            NSDictionary *w = wanted[key];
            if (!w || !outputUID || ![tap.processes isEqual:w[@"processes"]] || ![tap.outputUID isEqual:outputUID]) {
                if (gDiag) NSLog(@"sonora[debug] destroy tap %@ (wanted=%d)", key, w != nil);
                [self->_taps removeObjectForKey:key]; // dealloc tears it down
            }
        }
        if (!outputUID) return;
        [wanted enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *w, BOOL *stop) {
            float gain = [w[@"gain"] floatValue];
            SNTap *tap = self->_taps[key];
            if (tap) {
                if (gDiag && fabsf(gain - atomic_load(&tap.render->target)) > 1e-4) NSLog(@"sonora[debug] %@ gain -> %.3f", key, gain);
                [tap setGain:gain];
            } else if ((tap = [[SNTap alloc] initWithKey:key processes:w[@"processes"] outputUID:outputUID gain:gain])) {
                self->_taps[key] = tap;
                if (gDiag) NSLog(@"sonora[debug] create tap %@ gain %.3f processes %@", key, gain, w[@"processes"]);
            }
        }];
    });
}

- (double)volumeForKey:(NSString *)key {
    double v = 100;
    bool muted = false;
    return snGetSetting((char *)key.UTF8String, &v, &muted) ? v : 100;
}

- (BOOL)mutedForKey:(NSString *)key {
    double v = 100;
    bool muted = false;
    return snGetSetting((char *)key.UTF8String, &v, &muted) && muted;
}

- (void)setVolume:(double)percent muted:(BOOL)muted forKey:(NSString *)key {
    snSetSetting((char *)key.UTF8String, percent, muted);
    [self apply];
    [[NSNotificationCenter defaultCenter] postNotificationName:SNEngineVolumeDidChangeNotification object:self
        userInfo:@{@"key" : key, @"percent" : @(percent), @"muted" : @(muted)}];
}

- (void)resetAll {
    snResetAll();
    [self refresh];
}

- (void)shutdown {
    [_timer invalidate];
    dispatch_sync(_tapQueue, ^{ [self->_taps removeAllObjects]; });
    snFlush();
}
@end

#pragma mark - CLI

void SNListProcesses(void) {
    @autoreleasepool {
        for (SNApp *app in [SNEngine scanApps]) {
            printf("%-8s %-40s %s (%lu process%s)\n", app.inCall ? "CALL" : (app.playing ? "PLAYING" : "-"), app.key.UTF8String,
                   app.name.UTF8String, (unsigned long)app.processObjects.count,
                   app.processObjects.count == 1 ? "" : "es");
        }
    }
}
