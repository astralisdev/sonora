package main

import (
	"math"
	"testing"
)

const rate = 48000

func sine(freq, amp float64, frames int) []float32 {
	out := make([]float32, frames*2)
	for i := 0; i < frames; i++ {
		v := float32(amp * math.Sin(2*math.Pi*freq*float64(i)/rate))
		out[2*i], out[2*i+1] = v, v
	}
	return out
}

func peak(xs []float32) float32 {
	var p float32
	for _, x := range xs {
		p = max(p, float32(math.Abs(float64(x))))
	}
	return p
}

// At 100% the signal path must be bit-transparent apart from the look-ahead delay.
func TestUnityIsTransparent(t *testing.T) {
	d := newDSP(1, rate)
	defer d.close()
	in := sine(440, 0.5, rate)
	l, r := d.process(in)
	delay := dspLookahead - 1
	for i := delay; i < len(l); i++ {
		want := in[2*(i-delay)]
		if l[i] != want || r[i] != want {
			t.Fatalf("frame %d: got %v/%v, want %v", i, l[i], r[i], want)
		}
	}
}

// Boosting a loud signal must never exceed the ceiling, and must not reach the
// hard-clip safety net.
func TestBoostNeverClips(t *testing.T) {
	for _, freq := range []float64{50, 440, 1000, 8000} {
		d := newDSP(gainForPercent(150, false), rate)
		l, r := d.process(sine(freq, 0.95, rate))
		d.close()
		if p := max(peak(l), peak(r)); p > dspCeiling+1e-4 {
			t.Errorf("%v Hz: peak %v exceeds ceiling %v", freq, p, dspCeiling)
		}
	}
}

// The limiter must turn the volume down, not reshape the waveform: once settled
// on a steady tone, output/input should be (almost) a constant ratio. Per-sample
// saturation, the old source of crackle, would make the ratio swing widely.
func TestLimiterDoesNotDistort(t *testing.T) {
	for _, freq := range []float64{440, 1000, 5000} {
		gain := gainForPercent(150, false)
		d := newDSP(gain, rate)
		in := sine(freq, 0.9, rate)
		l, _ := d.process(in)
		d.close()
		delay := dspLookahead - 1
		lo, hi := math.Inf(1), math.Inf(-1)
		for i := rate / 2; i < len(l); i++ {
			x := float64(in[2*(i-delay)]) * float64(gain)
			if math.Abs(x) < 0.2 {
				continue
			}
			ratio := float64(l[i]) / x
			lo, hi = math.Min(lo, ratio), math.Max(hi, ratio)
		}
		if spread := (hi - lo) / hi; spread > 0.03 {
			t.Errorf("%v Hz: gain ratio varies by %.1f%% (%.3f–%.3f), the limiter is distorting", freq, spread*100, lo, hi)
		}
	}
}

// Moving a slider must ramp the gain, not step it.
func TestGainChangesAreSmooth(t *testing.T) {
	d := newDSP(0.25, rate)
	defer d.close()
	in := make([]float32, 512*2)
	for i := range in {
		in[i] = 0.5
	}
	var out []float32
	for block := 0; block < 8; block++ {
		if block == 4 {
			d.setGain(1)
		}
		l, _ := d.process(in)
		out = append(out, l...)
	}
	maxStep := float32(0.5*0.75/512) * 1.01
	for i := 1 + dspLookahead; i < len(out); i++ {
		if diff := float32(math.Abs(float64(out[i] - out[i-1]))); diff > maxStep {
			t.Fatalf("frame %d: jump of %v (max %v)", i, diff, maxStep)
		}
	}
}

func TestGainCurve(t *testing.T) {
	cases := []struct {
		percent float64
		muted   bool
		want    float64
	}{
		{0, false, 0}, {50, false, 0.25}, {100, false, 1}, {150, false, 1.9953},
		{120, false, 1.3183}, {-10, false, 0}, {1000, false, 1.9953}, {80, true, 0},
	}
	for _, c := range cases {
		if got := float64(gainForPercent(c.percent, c.muted)); math.Abs(got-c.want) > 1e-3 {
			t.Errorf("gainForPercent(%v, %v) = %.4f, want %.4f", c.percent, c.muted, got, c.want)
		}
	}
}
