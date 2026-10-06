package main

/*
#include <stdbool.h>
*/
import "C"

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// AppSetting is the persisted volume state of one app, keyed by bundle ID.
type AppSetting struct {
	Volume float64 `json:"volume"` // percent, 0–100 (100 = the app's own level)
	Muted  bool    `json:"muted,omitempty"`
}

// defaultCallDuckDB is how much other apps are lowered during a call, so music
// from the speakers doesn't leak into the microphone (echo cancellers remove
// speech well but music poorly).
const defaultCallDuckDB = 12

type store struct {
	mu    sync.Mutex
	path  string
	apps  map[string]AppSetting
	duck  *float64 // callDuckDB from settings.json
	timer *time.Timer
}

// settingsFile is the on-disk layout of settings.json.
type settingsFile struct {
	Apps       map[string]AppSetting `json:"apps"`
	CallDuckDB *float64              `json:"callDuckDB,omitempty"`
}

var settings = &store{apps: map[string]AppSetting{}}

func settingsPath() (string, error) {
	dir, err := os.UserConfigDir() // ~/Library/Application Support
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "Sonora", "settings.json"), nil
}

func (s *store) load() error {
	p, err := settingsPath()
	if err != nil {
		return err
	}
	s.path = p
	data, err := os.ReadFile(p)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	var file settingsFile
	if err := json.Unmarshal(data, &file); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for k, a := range file.Apps {
		if math.IsNaN(a.Volume) {
			continue
		}
		a.Volume = math.Max(0, math.Min(a.Volume, 100)) // 100% = the app's own level
		s.apps[k] = a
	}
	if d := file.CallDuckDB; d != nil && !math.IsNaN(*d) {
		v := math.Max(0, math.Min(*d, 100))
		s.duck = &v
	}
	return nil
}

// scheduleSave writes the settings shortly after the last change, so dragging a
// slider doesn't hit the disk on every tick. Caller holds s.mu.
func (s *store) scheduleSave() {
	if s.path == "" {
		return
	}
	if s.timer != nil {
		s.timer.Stop()
	}
	s.timer = time.AfterFunc(400*time.Millisecond, s.save)
}

func (s *store) save() {
	s.mu.Lock()
	data, err := json.MarshalIndent(settingsFile{Apps: s.apps, CallDuckDB: s.duck}, "", "  ")
	path := s.path
	s.mu.Unlock()
	if err != nil {
		return
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return
	}
	tmp := path + ".tmp"
	if os.WriteFile(tmp, data, 0o644) == nil {
		os.Rename(tmp, path)
	}
}

//export snGetSetting
func snGetSetting(key *C.char, volume *C.double, muted *C.bool) C.bool {
	settings.mu.Lock()
	defer settings.mu.Unlock()
	a, ok := settings.apps[C.GoString(key)]
	if !ok {
		return false
	}
	*volume = C.double(a.Volume)
	*muted = C.bool(a.Muted)
	return true
}

//export snSetSetting
func snSetSetting(key *C.char, volume C.double, muted C.bool) {
	settings.mu.Lock()
	defer settings.mu.Unlock()
	k := C.GoString(key)
	if float64(volume) == 100 && !bool(muted) {
		delete(settings.apps, k) // back to default, nothing to remember
	} else {
		settings.apps[k] = AppSetting{Volume: float64(volume), Muted: bool(muted)}
	}
	settings.scheduleSave()
}

//export snResetAll
func snResetAll() {
	settings.mu.Lock()
	defer settings.mu.Unlock()
	settings.apps = map[string]AppSetting{}
	settings.scheduleSave()
}

//export snFlush
func snFlush() {
	settings.mu.Lock()
	if settings.timer != nil {
		settings.timer.Stop()
	}
	settings.mu.Unlock()
	settings.save()
}

//export snCallDuckDB
func snCallDuckDB() C.double {
	settings.mu.Lock()
	defer settings.mu.Unlock()
	if settings.duck != nil {
		return C.double(*settings.duck)
	}
	return defaultCallDuckDB
}

//export snSetCallDuckDB
func snSetCallDuckDB(dB C.double) {
	settings.mu.Lock()
	defer settings.mu.Unlock()
	v := math.Max(0, math.Min(float64(dB), 100))
	settings.duck = &v
	settings.scheduleSave()
}
