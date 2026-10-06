package main

/*
#include <stdlib.h>
#include "dsp.h"

// The struct holds C11 atomics, which cgo can't describe, so Go only ever
// handles it as an opaque pointer.
static void *dspNew(float gain, double rate) {
	SNDSP *d = calloc(1, sizeof(SNDSP));
	if (d) sn_dsp_init(d, gain, rate);
	return d;
}
static void dspSetGain(void *d, float gain) { sn_dsp_set_gain(d, gain); }
static void dspProcess(void *d, const float *interleaved, unsigned frames) {
	sn_dsp_process(d, interleaved, 2, interleaved ? interleaved + 1 : NULL, 2, frames, frames);
}
static const float *dspOut(void *d, int ch) { return ch == 0 ? ((SNDSP *)d)->outL : ((SNDSP *)d)->outR; }
*/
import "C"

import "unsafe"

// dsp runs Sonora's real-time signal path (dsp.c) from Go, for tests and tooling.
type dsp struct{ p unsafe.Pointer }

func newDSP(gain float32, sampleRate float64) *dsp {
	return &dsp{C.dspNew(C.float(gain), C.double(sampleRate))}
}

func (d *dsp) close()               { C.free(d.p) }
func (d *dsp) setGain(gain float32) { C.dspSetGain(d.p, C.float(gain)) }

// process feeds interleaved stereo frames and returns the left and right output.
func (d *dsp) process(interleaved []float32) (left, right []float32) {
	const block = int(C.SN_MAX_FRAMES)
	for off := 0; off < len(interleaved)/2; off += block {
		n := min(block, len(interleaved)/2-off)
		C.dspProcess(d.p, (*C.float)(unsafe.Pointer(&interleaved[off*2])), C.unsigned(n))
		l := unsafe.Slice((*float32)(unsafe.Pointer(C.dspOut(d.p, 0))), n)
		r := unsafe.Slice((*float32)(unsafe.Pointer(C.dspOut(d.p, 1))), n)
		left = append(left, l...)
		right = append(right, r...)
	}
	return left, right
}

func gainForPercent(percent float64, muted bool) float32 {
	return float32(C.sn_gain_for_percent(C.double(percent), C.bool(muted)))
}

const (
	dspLookahead = int(C.SN_LOOKAHEAD)
	dspCeiling   = float32(C.SN_CEILING)
)
