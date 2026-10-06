# Tapmix

**Per-app volume control for macOS, right in your menu bar.**

Turn YouTube down while you're on a WhatsApp call, keep Spotify quiet under a Zoom meeting, or mute that one noisy tab without touching the system volume.

```
 ┌───────────────────────────────────────┐
 │ Output: MacBook Pro Speakers          │
 │ [▶] YouTube (Safari)  ━━━━━○──────  45% │
 │ [✆] WhatsApp          ━━━━━━━━━━○ 100% │
 │ [♫] Spotify           Muted            │
 ├───────────────────────────────────────┤
 │ Reset All to 100%                     │
 │ ✓ Launch at Login                     │
 │ Quit Tapmix                        ⌘Q │
 └───────────────────────────────────────┘
```

- One slider per app that is playing audio, from 0% to 150% (boost).
- Click an app's icon to mute it.
- Volumes are remembered per app and re-applied whenever it plays again.
- Browser and app helper processes are grouped under the app you know (Chrome, Safari, WhatsApp…).
- No audio driver or kernel extension to install, and no virtual device to pick. It works with whatever output you're using, including AirPods, and follows output changes automatically.
- Apps you leave at 100% are not touched at all.

## Requirements

- macOS **14.2 Sonoma** or newer (Apple Silicon or Intel)

## Install

### Download

Grab `Tapmix.zip` from [Releases](https://github.com/astralisdev/tapmix/releases), unzip it and move **Tapmix.app** to `/Applications`.
The app is not notarized yet, so the first time **right-click → Open** (or run `xattr -dr com.apple.quarantine /Applications/Tapmix.app`).

### Build from source

Requires Go 1.22+ and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/astralisdev/tapmix.git
cd tapmix
make install      # builds Tapmix.app, copies it to /Applications and launches it
```

Other targets: `make app` (build only, into `build/`), `make run`, `make universal` (arm64 + x86_64), `make zip`.

The first time you change an app's volume, macOS asks for permission to capture **system audio**. Allow it (System Settings → Privacy & Security → Screen & System Audio Recording → *System Audio Recording Only*). Tapmix needs it to read the app's audio and play it back at the new level. Nothing is recorded or sent anywhere.

Turn on **Launch at Login** from the menu to keep Tapmix running.

## How it works

Tapmix uses **Core Audio process taps** (`AudioHardwareCreateProcessTap`, added in macOS 14.2).

For every app whose volume is **not** 100%:

1. A private tap is created over all of the app's audio processes. Its mute behaviour is `CATapMutedWhenTapped`, so the app's own sound is silenced only while Tapmix is reading the tap.
2. A private aggregate device combines the current output device with that tap.
3. A real-time IOProc copies the tapped audio to the output, multiplied by the app's gain. Gain changes are ramped so they don't click.

When the app goes back to 100%, or has been quiet for a few seconds, the tap is torn down and the app plays directly again. If Tapmix quits or crashes, every app goes back to normal immediately, because a muted-when-tapped tap stops muting once nobody reads it.

### Code layout

| File | What it does |
| --- | --- |
| `main.go` | Entry point and CLI flags (`-list`, `-version`) |
| `settings.go` | Per-app settings saved to `~/Library/Application Support/Tapmix/settings.json` and exported to the native side |
| `engine.m` | Audio engine: process discovery and grouping, taps, aggregate devices, real-time gain |
| `ui.m` | Menu bar item and slider rows (AppKit) |

The UI and audio layers are Objective-C called through cgo, since AppKit and the real-time Core Audio callback have no pure-Go equivalent. Everything else is Go.

### Debugging

```sh
make app && ./build/Tapmix.app/Contents/MacOS/Tapmix -list
```

This prints every Core Audio client grouped the way Tapmix sees it, and marks the ones playing right now.

## Known limitations

- **Voice calls on speakers:** when a call app's volume is changed, its echo cancellation may not see the re-played audio, so the other side might hear an echo. Headphones avoid this. Leaving the call app at 100% (and lowering everything else) also avoids it.
- Volumes above 100% are hard-clipped, so heavy boosting of already-loud audio can distort.
- Output follows the system default device. Routing apps to different devices isn't supported (yet).

## Roadmap

- Per-app output device routing
- Global keyboard shortcuts
- Signed and notarized releases, Homebrew cask
- Optional Control Center / WidgetKit controls

Contributions are welcome. Open an issue or a PR.

## License

[MIT](LICENSE)
