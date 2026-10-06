// dsp.h — Sonora's real-time signal path: de-zippered gain + look-ahead peak
// limiter. Plain C with no Core Audio dependency, so it can be unit-tested.
#ifndef SONORA_DSP_H
#define SONORA_DSP_H

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

enum {
    SN_LOOKAHEAD = 64,    // frames (power of two); ~1.3 ms at 48 kHz, also the added latency
    SN_MAX_FRAMES = 8192, // largest block processed per call
};

#define SN_CEILING 0.891f // -1 dBFS

typedef struct {
    _Atomic float target; // user gain, written from any thread
    float current;        // gain reached at the end of the last block

    // limiter state
    float delay[2][SN_LOOKAHEAD];
    float hold[SN_LOOKAHEAD];
    float box[SN_LOOKAHEAD];
    float boxSum;
    float release;     // gain after release smoothing
    float releaseCoef; // per-frame recovery towards 1
    unsigned pos;

    float outL[SN_MAX_FRAMES], outR[SN_MAX_FRAMES];

    // Level meters, filled only when `meter` is set (debug aid, racy on purpose).
    bool meter;
    double inSq, outSq;
    uint64_t count;
    float inPeak, outPeak, minLimit;
} SNDSP;

void sn_dsp_init(SNDSP *d, float gain, double sampleRate);
void sn_dsp_set_gain(SNDSP *d, float gain);

// Processes `total` frames into d->outL/d->outR. Input frames past `inFrames`
// (or all of them when srcL is NULL) are treated as silence. srcR may equal srcL
// for mono. total must be <= SN_MAX_FRAMES.
void sn_dsp_process(SNDSP *d, const float *srcL, unsigned strideL, const float *srcR, unsigned strideR,
                    unsigned inFrames, unsigned total);

// Slider percent (0–100, 100 = the app's own level) → linear gain.
float sn_gain_for_percent(double percent, bool muted);

#endif
