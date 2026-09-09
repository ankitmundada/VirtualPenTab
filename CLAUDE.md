# VirtualPenTab — project notes for Claude Code

Fork of SideScreen (`upstream` remote) adding stylus pressure/tilt input from an
Android tablet to macOS. Read `README.md` first; it has the why, the diagrams,
and the table of bugs that looked like they worked. This file is the operational
layer: how to build, what bites, what's verified, what's next.

## Build, test, deploy

XCTest is unavailable without full Xcode, so Swift tests are a plain executable.
`swift test` will fail on a Command Line Tools install — that's expected.

```bash
# Mac
swift run --package-path MacHost CoreTests        # 115 checks; must say PASS
./scripts/build_mac.sh                            # SideScreen.app, signed
pkill -f SideScreen.app; open SideScreen.app      # relaunch

# Android (needs JDK 17 + Android SDK 34; set JAVA_HOME / ANDROID_HOME if not found)
cd AndroidClient && ./gradlew testDebugUnitTest assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

Only the side you changed needs redeploying; the wire protocol negotiates
capabilities, so a mismatched pair degrades to touch rather than breaking.

Logs: Mac writes `/tmp/sidescreen.log`; the client's is readable with
`adb shell run-as com.sidescreen.app cat files/diag.log`. Both are the first
place to look — the pen handshake, advisor output, congestion events and
display-mode selection all log there.

## Things that will bite you

- **Accessibility permission.** Without it `CGEvent.post` silently no-ops: video
  is perfect, pen does nothing. Screen Recording is the other required one.
- **Signing.** `build_mac.sh` signs with a `SideScreen Local Signing` self-signed
  cert if present, else ad-hoc — and ad-hoc means macOS re-asks for both
  permissions after every rebuild. Create the cert once (docs/pen-support.md).
  Do not use `security find-identity -v` to check for it; `-v` hides untrusted
  certs, and untrusted is fine for signing.
- **Never touch the encoder on the main thread.** `updateEncoderSettings` makes a
  blocking XPC call into VideoToolbox; from the main thread (or inside a
  `@Published` setter) it deadlocks the app. Everything goes via `encoderQueue`.
- **Do not rename the checkout directory** without `rm -rf MacHost/.build`; the
  module cache bakes in absolute paths and every file fails to compile.
- **MIUI/HyperOS** refuses `adb install` until "Install via USB" and "USB
  debugging (Security settings)" are on in Developer options.
- **macOS has no `timeout`.** For device captures run it on the Android side:
  `adb shell 'timeout 30 getevent -l /dev/input/eventN'`.

## Architecture in one breath

Two independent streams over one TCP connection: video Mac→tablet (untouched
upstream pipeline), pen tablet→Mac (this fork). Pen samples bypass the trackpad
gesture state machine in `AppDelegate` entirely — `PenInjector` posts mouse
events carrying the `tabletPoint` subtype, which is how real Wacom hardware
looks to AppKit. Pure logic lives in `MacHost/PenCore` and `MacHost/DisplayCore`
so it can be tested without the app; `Sources/` is the app itself.

Wire types added: 12 clientSupportsPen, 13 penEnabled (ack, host→client),
14 penEvent (23 bytes), 15 clientPanelInfo. Next free type is 16. New
client→host messages must either be payload-free, use the high-bit-set payload
convention (see type 11/15), or be gated behind an ack — an old host consumes
unknown types one byte at a time.

## Verified vs not (as of this writing)

Verified on Xiaomi Pad 5 + Smart Pen → macOS 26: pressure, hover, continuous
strokes, cursor hiding in proximity, HiDPI mode selection, rotation, live
reconfigure without disconnect, USB and Wi-Fi, adaptive bitrate under real
Wi-Fi congestion (one backoff 18→12 Mbps, additive recovery to ceiling in 34 s,
no oscillation, zero drops).

Not yet verified on hardware:
- **Tilt sign convention** — the math is tested, the physical direction of
  +tiltX/+tiltY on this digitizer is not. `tools/capture-tilt.sh` records the
  raw values; if mirrored, flip the sign in `PenTilt.toCartesian` and add a test.
- Barrel-button right-click; eraser tip.

## Known limitations and likely next steps

- Rebuilding the virtual display (rotation/resolution) evacuates windows to the
  main display. Positions are recoverable via the Accessibility API; Spaces are
  not (macOS doesn't expose them). A cheap partial fix: skip the rebuild when
  the new geometry equals what's live.
- Advisor link bandwidth is a constant (250 USB / 100 wireless Mbps). Measured
  to be non-binding in every real config; the adaptive controller covers the
  case that matters. A probe would mostly be a diagnostic readout.
- Hover is binary on this digitizer (`ABS_DISTANCE` 0–1); graded height is not
  supportable.

## Working conventions here

- Tests first for anything in PenCore/DisplayCore; both are pure and fast.
- Anything that *looked* like it worked but didn't goes in the README table.
- Commit messages carry the rationale — the "why", the measurement, the
  rejected alternative. `git log` is a context source, treat it as one.
- Hardware validation counts; unit tests passed for two bugs that only Wi-Fi
  playback and a real stylus exposed. Say "not verified" when it isn't.

## Upstream

`upstream` = tranvuongquocdat/SideScreen, forked at 4f1a05b. Upstream has moved
on (0.11.3+); before merging, read their commit "honour decoder limit and
geometry opt-in that arrive after protocol startup" — it is adjacent to the
panel-info work and may overlap. Upstream PR #33 attempted stylus support with a
breaking wire change; the design doc explains why this fork didn't reuse it.
