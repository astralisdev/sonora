// engine.m — per-app volume using Core Audio process taps (macOS 14.2+).
//
// For every app whose volume is not 100%, Sonora creates:
//   1. a private process tap over all of the app's audio processes, which
//      mutes the app's own output while Sonora is reading from it, and
//   2. a private aggregate device made of the current output device plus
//      that tap, whose IOProc copies the tapped audio to the output scaled
//      by the app's gain and passed through a look-ahead peak limiter.
// Apps at 100% are left untouched, so Sonora adds no latency to them.

#import "engine.h"
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#include <dlfcn.h>
#include <libproc.h>
#include <stdatomic.h>
#include "_cgo_export.h"
#include "dsp.h"

NSNotificationName const SNEngineAppsDidChangeNotification = @"SNEngineAppsDidChange";
NSNotificationName const SNEngineVolumeDidChangeNotification = @"SNEngineVolumeDidChange";

// How long a tap is kept after its app goes quiet, so pausing and resuming a
// video doesn't rebuild the tap (and briefly play at full volume) every time.
static const NSTimeInterval kTapGracePeriod = 30.0;

// How long a tap is kept after its volume returns to 100%, so dragging a
// slider across 100% doesn't tear the tap down and rebuild it.
static const NSTimeInterval kUnityHold = 15.0;

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

static NSArray<NSNumber *> *readScopedObjectList(AudioObjectID obj, AudioObjectPropertySelector sel,
                                                  AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a = addr(sel, scope);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(obj, &a, 0, NULL, &size) != noErr || size == 0) return @[];
    NSMutableData *data = [NSMutableData dataWithLength:size];
    if (AudioObjectGetPropertyData(obj, &a, 0, NULL, &size, data.mutableBytes) != noErr) return @[];
    NSMutableArray *out = [NSMutableArray new];
    const AudioObjectID *ids = data.bytes;
    for (UInt32 i = 0; i < size / sizeof(AudioObjectID); i++) [out addObject:@(ids[i])];
    return out;
}

// True when the process runs Apple's voice processing (what call apps use).
// Its echo canceller reads back the output device as an input, so the same
// device shows up in both the process's input and output device lists.
static BOOL usesVoiceProcessing(AudioObjectID process) {
    NSArray *inputs = readScopedObjectList(process, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeInput);
    if (inputs.count == 0) return NO;
    NSArray *outputs = readScopedObjectList(process, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput);
    for (NSNumber *d in outputs) if ([inputs containsObject:d]) return YES;
    return NO;
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

#pragma mark - Model

@implementation SNApp
@end

#pragma mark - Real-time render

typedef struct {
    UInt32 tapBuffers; // the tap's buffers are the last ones in the input list
    SNDSP dsp;
} SNRender;

static BOOL gDiag;
static double dB(double x) { return x > 1e-9 ? 20 * log10(x) : -999; }

// Runs on Core Audio's real-time thread: no locks, no allocation, no ObjC.
// Unpacks the tap's input, runs the DSP and writes left/right to the first two
// output channels.
static void render(SNRender *r, const AudioBufferList *in, AudioBufferList *out) {
    // The tap is a stereo mixdown: one interleaved buffer, or two mono ones.
    const float *srcL = NULL, *srcR = NULL;
    UInt32 strideL = 0, strideR = 0, inFrames = 0;
    if (in && r->tapBuffers > 0 && in->mNumberBuffers >= r->tapBuffers) {
        const AudioBuffer *b0 = &in->mBuffers[in->mNumberBuffers - r->tapBuffers];
        if (b0->mData && b0->mNumberChannels) {
            srcL = b0->mData;
            strideL = b0->mNumberChannels;
            inFrames = b0->mDataByteSize / (UInt32)(sizeof(float) * strideL);
            if (strideL >= 2) {
                srcR = srcL + 1;
                strideR = strideL;
            } else if (r->tapBuffers >= 2) {
                const AudioBuffer *b1 = &in->mBuffers[in->mNumberBuffers - r->tapBuffers + 1];
                if (b1->mData && b1->mNumberChannels) {
                    srcR = b1->mData;
                    strideR = b1->mNumberChannels;
                    UInt32 f1 = b1->mDataByteSize / (UInt32)(sizeof(float) * strideR);
                    if (f1 < inFrames) inFrames = f1;
                }
            }
        }
    }

    UInt32 frames = UINT32_MAX;
    for (UInt32 b = 0; b < out->mNumberBuffers; b++) {
        AudioBuffer *ab = &out->mBuffers[b];
        if (!ab->mData) continue;
        memset(ab->mData, 0, ab->mDataByteSize);
        if (ab->mNumberChannels) {
            UInt32 f = ab->mDataByteSize / (UInt32)(sizeof(float) * ab->mNumberChannels);
            if (f < frames) frames = f;
        }
    }
    if (frames == UINT32_MAX) return;
    if (frames > SN_MAX_FRAMES) frames = SN_MAX_FRAMES;

    // Always run the full output length so the limiter's delay line keeps moving.
    sn_dsp_process(&r->dsp, srcL, strideL, srcR, strideR, inFrames, frames);

    UInt32 oc = 0;
    for (UInt32 b = 0; b < out->mNumberBuffers; b++) {
        AudioBuffer *ab = &out->mBuffers[b];
        UInt32 n = ab->mNumberChannels;
        if (!ab->mData || n == 0) continue;
        float *dst = ab->mData;
        for (UInt32 c = 0; c < n; c++, oc++) {
            if (oc > 1) continue;
            const float *s = oc == 0 ? r->dsp.outL : r->dsp.outR;
            for (UInt32 i = 0; i < frames; i++) dst[i * n + c] = s[i];
        }
    }
}

#pragma mark - Tap

// One live tap + aggregate device. Created, changed and destroyed only on the engine's tap queue.
@interface SNTap : NSObject
@property(nonatomic, copy) NSArray<NSNumber *> *processes;
@property(nonatomic, copy) NSString *outputUID;
@property(nonatomic, readonly) SNRender *render;
@end

@implementation SNTap {
    AudioObjectID _tapID, _aggID;
    AudioDeviceIOProcID _procID;
    CATapDescription *_desc;
}

- (instancetype)initWithKey:(NSString *)key processes:(NSArray<NSNumber *> *)processes
                  outputUID:(NSString *)outputUID gain:(float)gain {
    if (!(self = [super init])) return nil;
    _processes = [processes copy];
    _outputUID = [outputUID copy];
    _render = calloc(1, sizeof(SNRender));

    _desc = [[CATapDescription alloc] initStereoMixdownOfProcesses:processes];
    _desc.name = [@"Sonora " stringByAppendingString:key];
    _desc.privateTap = YES;
    // Muted only while Sonora reads the tap: if Sonora stops or crashes the
    // app is audible again rather than silenced.
    _desc.muteBehavior = CATapMutedWhenTapped;

    OSStatus err = AudioHardwareCreateProcessTap(_desc, &_tapID);
    if (err != noErr) {
        NSLog(@"sonora: creating tap for %@ failed (%d)", key, (int)err);
        [self teardown];
        return nil;
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
            @kAudioSubTapUIDKey : _desc.UUID.UUIDString,
            @kAudioSubTapDriftCompensationKey : @YES,
        } ],
    };
    err = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)agg, &_aggID);
    if (err != noErr) {
        NSLog(@"sonora: creating aggregate device for %@ failed (%d)", key, (int)err);
        [self teardown];
        return nil;
    }

    AudioObjectPropertyAddress ra = addr(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal);
    Float64 rate = 0;
    UInt32 size = sizeof(rate);
    AudioObjectGetPropertyData(_aggID, &ra, 0, NULL, &size, &rate);
    sn_dsp_init(&_render->dsp, gain, rate);
    _render->dsp.meter = gDiag;
    _render->tapBuffers = 1;

    AudioObjectPropertyAddress fa = addr(kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal);
    AudioStreamBasicDescription fmt = {0};
    size = sizeof(fmt);
    if (AudioObjectGetPropertyData(_tapID, &fa, 0, NULL, &size, &fmt) == noErr &&
        (fmt.mFormatFlags & kAudioFormatFlagIsNonInterleaved) && fmt.mChannelsPerFrame > 0) {
        _render->tapBuffers = fmt.mChannelsPerFrame;
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

// Points the existing tap at a new set of processes (e.g. a browser opened a
// new tab process) without the glitch of rebuilding it.
- (BOOL)updateProcesses:(NSArray<NSNumber *> *)processes {
    _desc.processes = processes;
    CATapDescription *desc = _desc;
    AudioObjectPropertyAddress a = addr(kAudioTapPropertyDescription, kAudioObjectPropertyScopeGlobal);
    OSStatus err = AudioObjectSetPropertyData(_tapID, &a, 0, NULL, sizeof(desc), &desc);
    if (err != noErr) return NO;
    _processes = [processes copy];
    return YES;
}

// Debug: levels since the last call.
- (NSString *)takeStats {
    SNDSP *r = &_render->dsp;
    double n = r->count ? (double)r->count : 1;
    NSString *s = [NSString stringWithFormat:
        @"in rms %6.1f peak %6.1f | out rms %6.1f peak %6.1f dB | limiter %5.1f dB | gain %.3f",
        dB(sqrt(r->inSq / n)), dB(r->inPeak), dB(sqrt(r->outSq / n)), dB(r->outPeak), dB(r->minLimit),
        atomic_load(&r->target)];
    r->inSq = r->outSq = 0; r->inPeak = r->outPeak = 0; r->count = 0; r->minLimit = 1;
    return s;
}

- (void)setGain:(float)gain {
    sn_dsp_set_gain(&_render->dsp, gain);
}

- (float)gain {
    return atomic_load_explicit(&_render->dsp.target, memory_order_relaxed);
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
    NSMutableDictionary<NSString *, SNTap *> *_taps;            // tap queue only
    NSMutableDictionary<NSString *, NSDate *> *_lastPlaying;    // main thread only
    NSMutableDictionary<NSString *, NSDate *> *_lastNonUnity;   // main thread only
    NSMutableSet<NSNumber *> *_observedProcesses;               // main thread only
    NSArray<SNApp *> *_apps;
    NSString *_outputDeviceName;
    NSString *_outputUID;
    NSTimer *_timer;
    BOOL _refreshPending;
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
    _lastNonUnity = [NSMutableDictionary new];
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
            if (!e) return;
            dispatch_async(e->_tapQueue, ^{
                for (NSString *key in e->_taps) NSLog(@"sonora[debug] %@: %@", key, [e->_taps[key] takeStats]);
            });
        }];
    }
    AudioObjectPropertyListenerBlock changed = ^(UInt32 n, const AudioObjectPropertyAddress *a) {
        [weakSelf setNeedsRefresh];
    };
    AudioObjectPropertyAddress procs = addr(kAudioHardwarePropertyProcessObjectList, kAudioObjectPropertyScopeGlobal);
    AudioObjectPropertyAddress dev = addr(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal);
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &procs, dispatch_get_main_queue(), changed);
    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &dev, dispatch_get_main_queue(), changed);

    // Listeners cover starts/stops; the timer handles grace-period expiry.
    _timer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) { [weakSelf refresh]; }];
    _timer.tolerance = 0.5;
    [self refresh];
}

// Core Audio often fires several notifications in a burst (a browser starting
// a few processes at once); coalesce them into one rescan.
- (void)setNeedsRefresh {
    if (_refreshPending) return;
    _refreshPending = YES;
    __weak SNEngine *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        SNEngine *e = weakSelf;
        if (!e) return;
        e->_refreshPending = NO;
        [e refresh];
    });
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
        BOOL call = playing && listening && usesVoiceProcessing(pobj);

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
        app.inCall = app.inCall || call;
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
                ^(UInt32 n, const AudioObjectPropertyAddress *x) { [weakSelf setNeedsRefresh]; });
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
    NSDate *now = [NSDate date];
    NSMutableDictionary<NSString *, NSDictionary *> *wanted = [NSMutableDictionary new];
    for (SNApp *app in _apps) {
        float gain = sn_gain_for_percent([self volumeForKey:app.key], [self mutedForKey:app.key]);
        if (gain != 1.f) _lastNonUnity[app.key] = now;
        NSDate *last = _lastNonUnity[app.key];
        BOOL holding = last && [now timeIntervalSinceDate:last] < kUnityHold;
        if (gain == 1.f && !holding) continue;
        // macOS raises call audio by a fixed amount *after* the point where taps
        // read it (about +20 dB, measured), so a replayed call needs that boost
        // back to sound the same as the original.
        if (app.inCall) gain *= (float)pow(10.0, snCallBoostDB() / 20.0);
        wanted[app.key] = @{@"processes" : app.processObjects, @"gain" : @(gain)};
    }
    [self reconcile:wanted outputUID:_outputUID];
}

// Makes the set of live taps match `wanted` (key → processes + gain).
- (void)reconcile:(NSDictionary<NSString *, NSDictionary *> *)wanted outputUID:(NSString *)outputUID {
    dispatch_async(_tapQueue, ^{
        for (NSString *key in self->_taps.allKeys) {
            SNTap *tap = self->_taps[key];
            NSDictionary *w = wanted[key];
            BOOL keep = w && outputUID && [tap.outputUID isEqual:outputUID];
            if (keep && ![tap.processes isEqual:w[@"processes"]]) {
                keep = [tap updateProcesses:w[@"processes"]];
                if (gDiag) NSLog(@"sonora[debug] %@ processes -> %@ (%@)", key, w[@"processes"], keep ? @"updated" : @"rebuild");
            }
            if (!keep) {
                if (gDiag) NSLog(@"sonora[debug] destroy tap %@", key);
                [self->_taps removeObjectForKey:key]; // dealloc tears it down
            }
        }
        if (!outputUID) return;
        [wanted enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *w, BOOL *stop) {
            float gain = [w[@"gain"] floatValue];
            SNTap *tap = self->_taps[key];
            if (tap) {
                if (gDiag && fabsf(gain - tap.gain) > 1e-4) NSLog(@"sonora[debug] %@ gain -> %.3f", key, gain);
                [tap setGain:gain];
            } else if ((tap = [[SNTap alloc] initWithKey:key processes:w[@"processes"] outputUID:outputUID gain:gain])) {
                self->_taps[key] = tap;
                if (gDiag) NSLog(@"sonora[debug] create tap %@ gain %.3f", key, gain);
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

#pragma mark - Calibration

// Debug: alternates an app's direct audio with Sonora's replay at several
// compensation gains (spoken labels), to find the gain that matches direct.
void SNCalibrate(const char *bundleID) {
    @autoreleasepool {
        SNApp *target = nil;
        for (SNApp *app in [SNEngine scanApps]) if ([app.key isEqualToString:@(bundleID)]) target = app;
        if (!target) { printf("no audio process for %s\n", bundleID); return; }
        NSString *uid = readString(defaultOutputDevice(), kAudioDevicePropertyDeviceUID);
        struct { const char *label; double dB; } steps[] = {
            {"direct", -1}, {"plus ten", 10}, {"direct", -1}, {"plus twenty", 20},
            {"direct", -1}, {"plus fifteen", 15}, {"direct", -1}, {"plus twenty five", 25},
        };
        printf("The step that sounds like \"direct\" is your callBoostDB (settings.json, default 20).\n");
        int count = sizeof(steps) / sizeof(steps[0]);
        printf("Calibrating %s. Compare each step with the \"direct\" before it. 6 s per step.\n", target.name.UTF8String);
        for (int i = 0; i < count; i++) {
            printf("[%d/%d] %s\n", i + 1, count, steps[i].label);
            fflush(stdout);
            [NSTask launchedTaskWithExecutableURL:[NSURL fileURLWithPath:@"/usr/bin/say"]
                arguments:@[ @"-v", @"Samantha", @(steps[i].label) ] error:nil terminationHandler:nil];
            [NSThread sleepForTimeInterval:1.5];
            SNTap *tap = nil;
            if (steps[i].dB >= 0) {
                tap = [[SNTap alloc] initWithKey:target.key processes:target.processObjects outputUID:uid
                                            gain:(float)pow(10, steps[i].dB / 20)];
                if (!tap) { printf("tap failed\n"); return; }
            }
            [NSThread sleepForTimeInterval:4.5];
            tap = nil;
        }
        printf("done\n");
    }
}
