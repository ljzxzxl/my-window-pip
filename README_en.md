# MyWindowPip

Mirror **any macOS window (or any screen region) into an always-on-top floating window**, built for watching things over long stretches: slow builds, AI agent progress, logs, CI dashboards, web videos with no native PiP.

It uses the system [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) to capture a single window (never the whole screen), with per-app frame rates and idle detection, so CPU usage is close to zero at low frame rates.

- Open source (MIT), no account, no network access (except the update check you trigger)
- Universal binary (Intel + Apple Silicon), macOS 14 or later
- Builds with only the Xcode Command Line Tools — full Xcode is not required

## Features

**Picture-in-Picture**
- Turn the frontmost window into a PiP with one hotkey (`⌃⌥P` by default), or pick a window from the menu bar list
- Capture any screen region (`⌃⌥⇧P`); if the selection lands inside a window, a window stream is used instead, so it follows the window and keeps working when the window is covered
- Multiple PiP windows at once, cascaded automatically; position and width remembered per app
- Floating, borderless, aspect-locked, visible on all Spaces and above full-screen apps

**Zoom & pan**
- `Cmd` + drag to zoom into a region, `Cmd` + double-click to reset
- Scroll to pan when zoomed, `Cmd` + scroll to change the zoom factor (anchored at the pointer), 1×–20×
- Cropping happens on the capture side (`sourceRect`), so zooming keeps native pixels and stays sharp instead of interpolating a small image

**Efficiency**
- Per-app frame rate: 1 / 5 / 10 / 15 / 30 / 60 fps; terminals and editors default to 5 fps
- Idle detection drops to 1 fps when nothing changes and restores instantly when it does
- Streaming pauses automatically when the PiP window is fully occluded or on an inactive Space
- Frame rate, resolution and crop changes all go through `SCStream.updateConfiguration` — no stream rebuild, no black frames

**Interaction**
- On first launch a **dimmed overlay with an arrow** points at the menu bar icon, so it's obvious the app is running in the background and where the entry point is; you can replay it from "Show Getting Started" in the menu
- **Click a PiP window to switch straight to its source app** (can be turned off in Settings); with Accessibility granted it also raises that specific window
- Auto-hide with click-through: the window fades out and pauses when the pointer moves over it, so you can work with what's behind it — but the **top bar stays usable**: rest the pointer on the bar and the window returns to full opacity so you can click buttons, drag it by the bar, or open the right-click menu, while the video area stays click-through
- While faded you can also **hold `⌥` to peek at the whole window**, or turn auto-hide off from the window's menu bar submenu
- The faded opacity is configurable in 5% steps (default 35%) from Settings, the window's right-click menu, or the menu bar submenu
- Hover overlay controls: pause, frame rate, reset zoom, auto-hide, idle detection, close; icons highlight on hover and the description appears **instantly, above the icon** (drawn in its own window, so it is never hidden behind the PiP)
- The right-click menu exposes every action, so the app is fully usable without extra permissions
- Every entry under "Active PiP" in the menu bar has a submenu: bring to front / pause / auto-hide / idle detection / opacity / frame rate / close
- Source minimized → placeholder and automatic resume; source closed → notice, then auto-close; source app relaunched → reconnect by app + title
- Update check via GitHub Releases

## Shortcuts

| Action | Default | Notes |
|---|---|---|
| PiP frontmost window | `⌃⌥P` | configurable |
| Capture region | `⌃⌥⇧P` | configurable |
| Close all | `⌃⌥\` | configurable |
| Grab a whole window | `⌥`-click | while selecting |
| Cancel selection | `⎋` or right-click | while selecting |
| Zoom | `Cmd` + drag / `Cmd` + scroll | pointer over PiP |
| Reset zoom | `Cmd` + double-click | pointer over PiP |
| Pan | scroll | when zoomed |
| **Switch to the source window** | click the PiP | can be disabled in Settings |
| **Peek at a faded window** | hold `⌥`, or rest the pointer on the top bar | while auto-hide has faded it to click-through |

**Enhanced mode (optional, requires Accessibility)** adds:

| Action | Shortcut |
|---|---|
| PiP frontmost / capture region | `fn`+`P` / `fn`+`⇧`+`P` |
| Zoom in / out | `=` / `-` while hovering |
| Cycle frame rate | `F` while hovering |
| Toggle idle detection | `D` while hovering |
| Hide / show | tap `fn` while hovering (auto-closes after 60s hidden) |
| Close | `⌫` while hovering |

Enhanced mode is off by default. When on, only the keys above are intercepted, hover keys apply only while the pointer is inside a PiP window, and everything else passes through untouched.

## Permissions

| Permission | Required | Purpose |
|---|---|---|
| Screen & System Audio Recording | **yes** | ScreenCaptureKit window capture |
| Accessibility | optional | enhanced mode only (fn hotkeys, hover keys) |

Frames stay in local memory and VRAM: nothing is written to disk, uploaded, or reported.

The system permission prompt appears on first launch and the app registers itself under System Settings → Privacy & Security → Screen & System Audio Recording, so **you just flip the switch — no need to add it manually with the "+" button**. macOS only applies the grant after a restart; the guide dialog has a "Relaunch app" button for that.

> Ad-hoc signed apps get a new code hash on every build, so macOS may ask for Screen Recording again.
> Run `bash scripts/reset-permission.sh` after rebuilding, or use `bash scripts/build-app.sh --install`
> to keep the app at a stable path in `/Applications`.

## Frame rate guide

| Use case | Suggested |
|---|---|
| Terminals, logs, build output | 1–5 fps |
| AI agent progress, CI, dashboards | 5–15 fps |
| Chat, community feeds | 10–15 fps |
| Video, animation | 30–60 fps |

## Measured usage

Intel i5, macOS 26.5, 1920×1080@2x main display, capturing a 1920×993 window into a 640pt-wide PiP:

| Scenario | CPU | Resident memory |
|---|---|---|
| 1 stream · 1 fps | 0.1–0.4% (occasional 3% spike) | ~62 MB |
| 1 stream · 30 fps (low-motion content) | 1.5–2.0% | ~62 MB |
| 3 streams · 15 fps · 70 s | 1.8–2.6% | 62.1 → 62.3 MB (no upward trend) |

About 55 MB of that is the AppKit/ScreenCaptureKit baseline and is independent of the number of PiP windows.

## Build

Only the Xcode Command Line Tools are needed:

```bash
bash scripts/build-app.sh              # build/MyWindowPip.app (x86_64 + arm64)
bash scripts/build-app.sh --fast       # current architecture only
bash scripts/build-app.sh --debug      # DEBUG logging + geometry self-checks
bash scripts/build-app.sh --install    # also install to /Applications
open build/MyWindowPip.app
```

If Gatekeeper blocks the first launch, right-click the app in Finder → Open.

Self-test (no UI; verifies permissions and the whole capture path):

```bash
./build/MyWindowPip.app/Contents/MacOS/my-window-pip --selftest
```

## Package a DMG

```bash
bash scripts/build-app.sh
bash packaging/make-dmg.sh     # dist/MyWindowPip-<version>.dmg + SHA256
```

Pushing a tag (e.g. `v0.1.0`, must match `VERSION`) builds and publishes a GitHub Release.

## Known limits

- Requires macOS 14+ so that `SCStream.updateConfiguration` can retune frame rate/resolution/crop smoothly; no 12.3–13 compatibility path
- `fn` combinations and hover keys require an event tap, so they live in the optional Accessibility-gated enhanced mode
- While a source window is minimized the system produces no frames, so a placeholder is shown until it comes back (a macOS limitation, not a bug)
- Launch at login uses `SMAppService`, which can fail for ad-hoc signed apps; the app then points you to System Settings

## Not implemented yet (v2 backlog)

- Audio follow (the `capturesAudio` hook is already in place)
- Image filters such as contrast enhancement (a filter hook exists in the render layer)
- Command-line control of a running instance (`--app/--window/--zoom`)

## License

MIT, see `LICENSE`. Inspired by [Pipiri](https://lowtechguys.com/pipiri/); this is an independent implementation and contains none of its code.
