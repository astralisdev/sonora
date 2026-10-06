// sonora.h — C API shared between the Go side and the Objective-C side.
#ifndef SONORA_H
#define SONORA_H

// Runs the Cocoa menu bar app. Never returns. Must be called on the main thread.
void SNRun(void);

// Prints every process currently known to Core Audio, grouped by app (debug aid).
void SNListProcesses(void);

// Debug: alternates direct audio with compensated replays to find a matching gain.
void SNCalibrate(const char *bundleID);

#endif
