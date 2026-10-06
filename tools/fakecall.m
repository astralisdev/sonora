// fakecall — a stand-in for a voice call, for testing Sonora without calling
// anyone. It runs Apple's voice-processing audio unit (the echo canceller call
// apps use, which is what makes macOS and Sonora treat a process as a call),
// keeps the microphone running, and plays a spoken voice on a loop, like the
// other person talking.
//
// Usage: fakecall [seconds]   (default 60; needs microphone permission)
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

static const double kRate = 48000;

typedef struct {
    AudioUnit unit;
    float *voice;        // mono voice at kRate
    UInt32 voiceFrames, position;
    float mic[4096];     // scratch for the microphone input we read and discard
} FakeCall;

// Output: the "other person" talking.
static OSStatus playVoice(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                          UInt32 bus, UInt32 frames, AudioBufferList *data) {
    FakeCall *c = ref;
    float *out = data->mBuffers[0].mData;
    for (UInt32 i = 0; i < frames; i++) {
        out[i] = c->voice[c->position];
        c->position = (c->position + 1) % c->voiceFrames;
    }
    return noErr;
}

// Input: a call keeps reading the microphone; doing so keeps voice processing on.
static OSStatus readMic(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts,
                        UInt32 bus, UInt32 frames, AudioBufferList *unused) {
    FakeCall *c = ref;
    if (frames > 4096) return noErr;
    AudioBufferList abl = {1, {{1, frames * sizeof(float), c->mic}}};
    return AudioUnitRender(c->unit, flags, ts, 1, frames, &abl);
}

static void check(OSStatus err, const char *what) {
    if (err == noErr) return;
    fprintf(stderr, "fakecall: %s failed (%d)\n", what, (int)err);
    exit(1);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        double seconds = argc > 1 ? atof(argv[1]) : 60;

        // Voice processing needs the microphone; ask for it (macOS shows its prompt once).
        AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
        if (status == AVAuthorizationStatusNotDetermined) {
            dispatch_semaphore_t answered = dispatch_semaphore_create(0);
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
                dispatch_semaphore_signal(answered);
            }];
            dispatch_semaphore_wait(answered, DISPATCH_TIME_FOREVER);
            status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
        }
        if (status != AVAuthorizationStatusAuthorized) {
            fprintf(stderr, "fakecall: microphone access is off. Allow it for your terminal app in "
                            "System Settings → Privacy & Security → Microphone.\n");
            return 1;
        }

        // The "other person": a spoken sentence, rendered by `say` at our rate.
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"sonora-fakecall.wav"];
        NSString *script = @"Hi, this is a test call. I'm talking so you can check the volume of the call "
                           @"against your music. One, two, three, four, five. Can you hear me well?";
        NSTask *say = [NSTask launchedTaskWithExecutableURL:[NSURL fileURLWithPath:@"/usr/bin/say"]
            arguments:@[ @"--data-format=LEF32@48000", @"-o", path, script ] error:nil terminationHandler:nil];
        [say waitUntilExit];
        NSError *err = nil;
        AVAudioFile *file = [[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:path]
                                                   commonFormat:AVAudioPCMFormatFloat32 interleaved:NO error:&err];
        AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat
                                                               frameCapacity:(AVAudioFrameCount)file.length];
        if (!file || ![file readIntoBuffer:buf error:&err] || buf.frameLength == 0) {
            fprintf(stderr, "fakecall: can't prepare the voice: %s\n", err.localizedDescription.UTF8String);
            return 1;
        }

        FakeCall *call = calloc(1, sizeof(FakeCall));
        call->voiceFrames = buf.frameLength + (UInt32)kRate / 2; // half a second of pause between loops
        call->voice = calloc(call->voiceFrames, sizeof(float));
        memcpy(call->voice, buf.floatChannelData[0], buf.frameLength * sizeof(float));

        AudioComponentDescription desc = {kAudioUnitType_Output, kAudioUnitSubType_VoiceProcessingIO,
                                          kAudioUnitManufacturer_Apple, 0, 0};
        check(AudioComponentInstanceNew(AudioComponentFindNext(NULL, &desc), &call->unit), "creating voice processing");
        AudioUnit au = call->unit;
        UInt32 on = 1;
        check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, sizeof(on)),
              "enabling the microphone");

        AudioStreamBasicDescription mono = {
            .mSampleRate = kRate, .mFormatID = kAudioFormatLinearPCM,
            .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            .mBytesPerPacket = sizeof(float), .mFramesPerPacket = 1, .mBytesPerFrame = sizeof(float),
            .mChannelsPerFrame = 1, .mBitsPerChannel = 32,
        };
        check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &mono, sizeof(mono)),
              "setting the speaker format");
        check(AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &mono, sizeof(mono)),
              "setting the microphone format");

        AURenderCallbackStruct output = {playVoice, call}, input = {readMic, call};
        check(AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &output, sizeof(output)),
              "connecting the voice");
        check(AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &input, sizeof(input)),
              "connecting the microphone");

        check(AudioUnitInitialize(au), "starting voice processing");
        check(AudioOutputUnitStart(au), "starting audio");

        printf("fake call running for %.0f s\n", seconds);
        fflush(stdout);
        [NSThread sleepForTimeInterval:seconds];
        AudioOutputUnitStop(au);
        AudioUnitUninitialize(au);
        AudioComponentInstanceDispose(au);
        printf("fake call ended\n");
    }
    return 0;
}
