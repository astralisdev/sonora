// tapmix.h — C API shared between the Go side and the Objective-C side.
#ifndef TAPMIX_H
#define TAPMIX_H

// Runs the Cocoa menu bar app. Never returns. Must be called on the main thread.
void TMRun(void);

// Prints every process currently known to Core Audio, grouped by app (debug aid).
void TMListProcesses(void);

#endif
