// dsp.c — see dsp.h.
//
// The limiter lowers the gain smoothly *before* a peak arrives instead of
// bending individual samples (which is what crackles):
//   1. per frame, the gain needed to keep the louder channel under the ceiling,
//   2. smoothed with a slow release so the gain recovers without pumping,
//   3. min-held over the look-ahead window, then box-averaged over the same
//      window. The average reaches the required gain exactly when the delayed
//      peak comes out: a smooth ~1.3 ms attack with no overshoot.
// Both channels share one gain, so the stereo image never shifts.

#include "dsp.h"

#include <math.h>
#include <string.h>

void sn_dsp_init(SNDSP *d, float gain, double sampleRate) {
    memset(d, 0, sizeof(*d));
    atomic_store(&d->target, gain);
    d->current = gain;
    d->release = 1;
    double sr = sampleRate > 0 ? sampleRate : 48000;
    d->releaseCoef = (float)(1.0 - exp(-1.0 / (0.08 * sr))); // 80 ms
    for (int i = 0; i < SN_LOOKAHEAD; i++) d->hold[i] = d->box[i] = 1;
    d->boxSum = SN_LOOKAHEAD;
    d->minLimit = 1;
}

void sn_dsp_set_gain(SNDSP *d, float gain) {
    atomic_store_explicit(&d->target, gain, memory_order_relaxed);
}

void sn_dsp_process(SNDSP *d, const float *srcL, unsigned strideL, const float *srcR, unsigned strideR,
                    unsigned inFrames, unsigned total) {
    if (total > SN_MAX_FRAMES) total = SN_MAX_FRAMES;
    if (!srcL) inFrames = 0;
    if (!srcR) { srcR = srcL; strideR = strideL; }

    float target = atomic_load_explicit(&d->target, memory_order_relaxed);
    float g = d->current, step = total ? (target - d->current) / (float)total : 0; // de-zipper ramp
    float rel = d->release, boxSum = d->boxSum, coef = d->releaseCoef;
    unsigned pos = d->pos;

    for (unsigned i = 0; i < total; i++, g += step) {
        float xl = 0, xr = 0;
        if (i < inFrames) {
            xl = srcL[i * strideL];
            xr = srcR[i * strideR];
        }
        float bl = xl * g, br = xr * g;

        float peak = fmaxf(fabsf(bl), fabsf(br));
        float need = peak > SN_CEILING ? SN_CEILING / peak : 1.f;
        rel += (1.f - rel) * coef;
        if (need < rel) rel = need;

        d->hold[pos] = rel;
        float held = 1.f;
        for (int k = 0; k < SN_LOOKAHEAD; k++) held = fminf(held, d->hold[k]);
        boxSum += held - d->box[pos];
        d->box[pos] = held;
        float env = boxSum * (1.f / SN_LOOKAHEAD);

        d->delay[0][pos] = bl;
        d->delay[1][pos] = br;
        pos = (pos + 1) & (SN_LOOKAHEAD - 1);
        // The next slot holds the sample from SN_LOOKAHEAD-1 frames ago, which is
        // exactly when `env` has finished ramping down for it.
        float yl = d->delay[0][pos] * env, yr = d->delay[1][pos] * env;
        // Last-resort safety; with the limiter above this never triggers.
        d->outL[i] = fmaxf(-1.f, fminf(1.f, yl));
        d->outR[i] = fmaxf(-1.f, fminf(1.f, yr));

        if (d->meter) {
            d->count++;
            d->inSq += 0.5 * ((double)xl * xl + (double)xr * xr);
            d->outSq += 0.5 * ((double)yl * yl + (double)yr * yr);
            d->inPeak = fmaxf(d->inPeak, fmaxf(fabsf(xl), fabsf(xr)));
            d->outPeak = fmaxf(d->outPeak, fmaxf(fabsf(yl), fabsf(yr)));
            d->minLimit = fminf(d->minLimit, env);
        }
    }
    // Recompute the running sum so float error can't build up over hours.
    boxSum = 0;
    for (int k = 0; k < SN_LOOKAHEAD; k++) boxSum += d->box[k];

    d->pos = pos;
    d->release = rel;
    d->boxSum = boxSum;
    d->current = target;
}

// Below 100% the slider is squared (50% ≈ -12 dB, about half as loud to the
// ear). Above 100% it boosts in even dB steps up to +6 dB at 150%.
float sn_gain_for_percent(double percent, bool muted) {
    if (muted) return 0;
    percent = fmax(0, fmin(percent, 150));
    if (percent <= 100) {
        double x = percent / 100.0;
        return (float)(x * x);
    }
    return (float)pow(10.0, (percent - 100.0) / 50.0 * 6.0 / 20.0);
}
