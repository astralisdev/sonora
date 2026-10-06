// Tapmix is a macOS menu bar app that controls the volume of each app separately.
//
// The audio work is done with Core Audio process taps (macOS 14.2+): an app's
// output is captured by a private tap, scaled by the chosen gain, and played back
// on the current output device while the original stream is muted.
package main

/*
#cgo CFLAGS: -fobjc-arc -Wno-unused-command-line-argument
#cgo LDFLAGS: -framework Cocoa -framework CoreAudio -framework ServiceManagement
#include "tapmix.h"
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
	flag.Parse()

	switch {
	case *showVersion:
		fmt.Println("Tapmix", version)
		return
	case *list:
		C.TMListProcesses()
		return
	}

	if err := settings.load(); err != nil {
		fmt.Fprintln(os.Stderr, "tapmix: could not load settings:", err)
	}
	C.TMRun()
}
