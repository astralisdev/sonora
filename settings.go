package main

/*
#include <stdbool.h>
*/
import "C"

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// AppSetting is the persisted volume state of one app, keyed by bundle ID.
type AppSetting struct {
	Volume float64 `json:"volume"` // percent, 0–150
	Muted  bool    `json:"muted,omitempty"`
}

type store struct {
	mu    sync.Mutex
	path  string
	apps  map[string]AppSetting
	timer *time.Timer
}

var settings = &store{apps: map[string]AppSetting{}}

func settingsPath() (string, error) {
	dir, err := os.UserConfigDir() // ~/Library/Application Support
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "Tapmix", "settings.json"), nil
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
	var file struct {
		Apps map[string]AppSetting `json:"apps"`
	}
	if err := json.Unmarshal(data, &file); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if file.Apps != nil {
		s.apps = file.Apps
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
	data, err := json.MarshalIndent(struct {
		Apps map[string]AppSetting `json:"apps"`
	}{s.apps}, "", "  ")
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

//export tmGetSetting
func tmGetSetting(key *C.char, volume *C.double, muted *C.bool) C.bool {
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

//export tmSetSetting
func tmSetSetting(key *C.char, volume C.double, muted C.bool) {
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

//export tmResetAll
func tmResetAll() {
	settings.mu.Lock()
	defer settings.mu.Unlock()
	settings.apps = map[string]AppSetting{}
	settings.scheduleSave()
}

//export tmFlush
func tmFlush() {
	settings.mu.Lock()
	if settings.timer != nil {
		settings.timer.Stop()
	}
	settings.mu.Unlock()
	settings.save()
}
