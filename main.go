// Sonora is a macOS menu bar app that controls the volume of each app separately.
//
// The audio work is done with Core Audio process taps (macOS 14.2+): an app's
// output is captured by a private tap, scaled by the chosen gain, and played back
// on the current output device while the original stream is muted.
package main

/*
#cgo CFLAGS: -fobjc-arc -Wno-unused-command-line-argument
#cgo LDFLAGS: -framework Cocoa -framework CoreAudio -framework QuartzCore -framework ServiceManagement
#include "sonora.h"
*/
import "C"

import (
	"flag"
	"fmt"
	"os"
	"runtime"
)

var version = "dev"

func init() {
	// Cocoa must run on the process's main thread.
	runtime.LockOSThread()
}

func main() {
	showVersion := flag.Bool("version", false, "print the version and exit")
	list := flag.Bool("list", false, "list audio processes grouped by app and exit")
	snapshot := flag.String("snapshot", "", "debug: render a menu row for every audio process to this PNG file")
	welcomeShot := flag.String("snapshot-welcome", "", "debug: render the welcome window to this PNG file")
	compare := flag.String("compare", "", "debug: alternate an app (bundle ID) between direct playback and Sonora at 100%")
	tipShot := flag.String("snapshot-tip", "", "debug: render the call tip to this PNG file")
	flag.Parse()

	switch {
	case *showVersion:
		fmt.Println("Sonora", version)
		return
	case *snapshot != "":
		cs := C.CString(*snapshot)
		C.SNSnapshot(cs)
		return
	case *welcomeShot != "":
		cs := C.CString(*welcomeShot)
		C.SNSnapshotWelcome(cs)
		return
	case *compare != "":
		cs := C.CString(*compare)
		C.SNCompare(cs)
		return
	case *tipShot != "":
		cs := C.CString(*tipShot)
		C.SNSnapshotTip(cs)
		return
	case *list:
		C.SNListProcesses()
		return
	}

	if err := settings.load(); err != nil {
		fmt.Fprintln(os.Stderr, "sonora: could not load settings:", err)
	}
	C.SNRun()
}
