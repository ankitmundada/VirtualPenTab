# Pen Support — Design

**Status:** implemented and validated on hardware
**Date:** 2026-08-16
**Branch:** `pen-support`
**Scope:** local fork. Not currently intended for upstream submission.

---

## 1. Goal

Make a stylus on the Android client behave as a pressure- and tilt-sensitive
graphics tablet for macOS, so drawing apps receive real pen data rather than
plain mouse clicks.

Target hardware for validation: Xiaomi Pad 5 (`nabu`, Android 13) with the
Xiaomi Smart Pen, connected over USB.

### Why this is worth building

No open-source second-display tool currently delivers pen pressure to macOS:

| Project | Pen pressure on macOS |
|---|---|
| SideScreen (this fork's base) | No — touch only |
| Deskreen | No input at all |
| BetterCast | No |
| Weylus | Stylus support exists, but **Linux only** |

The gap is real, and both ends of the pipeline have now been measured to
confirm the data exists to fill it (§3, §4).

---

## 2. Prior art in the base repo

- **Issue #45** — the underlying user request. SideScreen currently cannot
  synthesize a *drag* at all: touch down → move → up does not become
  button-down → move → button-up, so a stylus can tap but cannot draw a line.
- **PR #33** — implements stylus pressure/tilt/hover. Parked by the maintainer
  pending "more careful testing across setups".
- **PR #51** (draft) — Mac-only "Pen/Draw Mode" toggle; the small half of #45,
  no protocol change.
- **PR #46** — releases a stuck mouse button during touch teardown.

### Why PR #33's approach is not reused

1. **Breaking wire change.** It redefines existing message type 2's payload
   from `2 + N*8 + 4` bytes to `2 + N*8 + 16`. The rest of the protocol is
   carefully forward-compatible — type 11 sets the high bit on every payload
   byte specifically *"so old hosts skip the payload harmlessly"*. Under #33,
   a newer client against an older host has its 26-byte frame read as 14
   bytes, and the remaining 12 are then parsed as message types, desyncing
   the input stream permanently.
2. **Lossy tilt.** It collapses tilt to a single float. Measurement (§3) shows
   the digitizer reports two independent signed axes, and macOS consumes two
   independent values, so this discards pen direction for no gain.
3. **13-argument callback.** `onTouchEvent` becomes 13 positional parameters.
4. Bundles an unrelated 2→4 pointer-count change.
5. No tests.

PR #46's stuck-button fix **is** adopted here (§6.3), with credit — a pen makes
a held mouse button the normal state of every stroke rather than a rare
long-press case.

---

## 3. Hardware measurement — Xiaomi Pad 5 digitizer

From `adb shell getevent -pl`, device `NVTCapacitivePen` (`/dev/input/event4`):

| Axis | Range | Note |
|---|---|---|
| `ABS_PRESSURE` | 0 – 4095 | 4096 levels (12 bits) |
| `ABS_TILT_X` | −60 … +60 | degrees, independent axis |
| `ABS_TILT_Y` | −60 … +60 | degrees, independent axis |
| `ABS_DISTANCE` | 0 – 1 | **binary hover only**, not graded height |
| `ABS_X` / `ABS_Y` | 12799 / 20479 | ~8× the 1600×2560 panel |
| `BTN_STYLUS`, `BTN_STYLUS2` | — | two barrel buttons |

Consequence: hover can be reported as in-range/out-of-range but **not** as a
graded distance. Any future "hover height" feature is not supportable on this
hardware.

---

## 4. Validation — macOS event injection

Verified on **macOS 26.3.1 (25D2128)** using a standalone ad-hoc-signed app
(`tools/penspike/`) so the Accessibility grant attaches to the spike itself
rather than to the terminal. It installs a *consuming* event tap that
recognises its own events by a magic device ID and swallows them, so no
synthetic click reaches a real application.

Result — every field survived the HID round trip byte-exact:

```
tabletProximity    pressure=0.000  tilt=(+0.000, +0.000)  subtype=0
mouseMoved         pressure=0.000  tilt=(-0.250, +0.500)  subtype=1
leftMouseDown      pressure=0.100  tilt=(-0.250, +0.500)  subtype=1
leftMouseDragged   pressure=0.450  tilt=(-0.250, +0.500)  subtype=1
leftMouseDragged   pressure=0.900  tilt=(-0.250, +0.500)  subtype=1
leftMouseUp        pressure=0.000  tilt=(-0.250, +0.500)  subtype=1
```

**Findings:**

- Graded pressure, two-axis tilt, and the `tabletPoint` subtype are all
  preserved through `CGEvent.post`.
- `CGEvent.post` silently no-ops without Accessibility permission —
  `AXIsProcessTrusted()` must be checked, as the existing code already does at
  `AppDelegate.swift:744`.
- A native `.tabletPointer` event type was also posted but not observed. This
  is **inconclusive** — the spike's wait loop exits at 6 events. It does not
  affect the design, which uses mouse events carrying the tablet subtype (the
  shape real Wacom hardware presents to AppKit).

---

## 5. Wire protocol

### 5.1 Approach

Pen data must reach the host without breaking a mismatched build pair. Both
sides are built locally and will frequently be rebuilt independently during
development, so version skew is a practical concern, not a theoretical one.

The base protocol already contains the needed pattern: type 10
(`codecSelected`) is *"sent ONLY to clients that sent clientAvcOnly — old
clients disconnect on unknown message types"*. This design mirrors it.

| Type | Direction | Payload | Purpose |
|---|---|---|---|
| 12 `clientSupportsPen` | client → host | none | Capability opt-in, sent during handshake |
| 13 `penEnabled` | host → client | 1 byte (flags) | Ack; sent **only** to clients that sent type 12 |
| 14 `penEvent` | client → host | 22 bytes | Sent **only** after the ack is received |

Type 15 (`clientPanelInfo`) is also taken — it carries the client's real panel
geometry for the display advisor, using the high-bit-set payload convention of
type 11 rather than a capability ack. Next free type is 16.

Because a pen frame is never transmitted until the host has explicitly
confirmed it understands one, the payload can be plain little-endian binary
matching the existing `sendTouch` framing — no bit-packing needed.

**Skew behaviour:**

- New client + old host → host ignores type 12 (its `default:` branch consumes
  1 byte), never acks, client never sends pen frames, falls back to touch.
- New host + old client → client never sends type 12, host never enables pen,
  behaviour unchanged.

### 5.2 `penEvent` layout

Little-endian, matching the existing `ByteOrder.LITTLE_ENDIAN` convention:

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0 | 1 | type = 14 | |
| 1 | 1 | phase | 0=hoverEnter 1=hoverMove 2=down 3=move 4=up 5=hoverExit 6=cancel |
| 2 | 1 | buttons | bit0 = barrel1, bit1 = barrel2, bit2 = eraser |
| 3 | 4 | x | f32, normalized 0…1 (same convention as touch) |
| 7 | 4 | y | f32, normalized 0…1 |
| 11 | 4 | pressure | f32, 0…1 |
| 15 | 4 | tiltX | f32, −1…1 |
| 19 | 4 | tiltY | f32, −1…1 |

Total 23 bytes. At the pen's ~240 Hz sample rate that is ~5.5 KB/s, negligible
beside the video stream.

---

## 6. macOS host

### 6.1 `PenInjector.swift` (new)

Deliberately separate from the existing gesture state machine in
`AppDelegate`. That machine emulates a *trackpad* — tap, long-press, scroll,
pinch, momentum — whereas a pen is direct absolute pointing. Conflating the
two is the direct cause of issue #45, where a stroke longer than
`tapMaxDistance` is interpreted as a scroll.

Responsibilities:

- Own proximity state, button state, and the last posted point.
- Translate a `PenSample` plus display bounds into `CGEvent`s.
- Nothing else. It does not know about sockets or settings.

Event mapping:

| Phase | Posted event |
|---|---|
| hoverEnter | `.tabletProximity`, `enterProximity = 1`, pointerType pen/eraser |
| hoverMove | `.mouseMoved`, subtype tabletPoint, pressure 0 |
| down | `.leftMouseDown` (or `.rightMouseDown` if barrel1 held) |
| move | `.leftMouseDragged` with pressure + tilt |
| up | `.leftMouseUp` |
| hoverExit | `.tabletProximity`, `enterProximity = 0` |
| cancel | forced up, then proximity exit |

Every posted event carries `mouseEventSubtype = 1` (tabletPoint),
`tabletEventPointPressure`, `tabletEventTiltX/Y`, and a stable `deviceID`.

### 6.2 Coordinate mapping

Reuses the existing convention: normalized 0…1 against
`CGDisplayBounds(virtualDisplayID)`, exactly as `handleTouch` does at
`AppDelegate.swift:758`.

### 6.3 Stuck-button safety

A `releaseHeldMouseButtonIfNeeded()` path (adopted from PR #46) must fire on:
client disconnect, `stopServer()`, input toggled off, pen proximity lost
mid-stroke, and a fresh down arriving while a previous stroke is still open.
Without it, unplugging USB mid-stroke leaves the left button held down
system-wide.

---

## 7. Android client

### 7.1 `PenInput.kt` (new)

- Branch on `event.getToolType(i)`: `TOOL_TYPE_STYLUS` and `TOOL_TYPE_ERASER`
  take the pen path; everything else keeps the existing touch path.
- Hook `onGenericMotionEvent` as well as `onTouchEvent` — hover
  (`ACTION_HOVER_ENTER/MOVE/EXIT`) is only delivered to the former.
- Read `AXIS_PRESSURE`, `AXIS_TILT`, and `event.orientation`.
- Map `BTN_STYLUS` / `BTN_STYLUS2` from `buttonState`
  (`BUTTON_STYLUS_PRIMARY` / `BUTTON_STYLUS_SECONDARY`).

### 7.2 Historical samples

`MotionEvent` batches pen samples to the vsync tick. Reading only `getX()`
discards most of the 240 Hz data and produces visibly polygonal strokes.
The pen path must iterate `getHistoricalX/Y/Pressure/AxisValue` before
handling the current sample, emitting one `penEvent` per historical sample.

### 7.3 Tilt conversion

Android reports polar tilt; macOS wants Cartesian components.

```
tiltX = atan2(sin(tilt) * sin(orientation), cos(tilt))
tiltY = atan2(sin(tilt) * cos(orientation), cos(tilt))
```

Both are then normalized to −1…1 by dividing by π/2.

Sign conventions must be checked empirically against the real pen — this is
precisely the validation the upstream maintainer noted was missing from #33.

---

## 8. Settings

A single "Pen input" toggle in Touch Control, default **on** when a pen-capable
client connects. When off, stylus events fall through to the existing touch
gesture path, preserving current behaviour exactly.

Deliberately excluded for now (YAGNI): pressure curves, per-app profiles,
button remapping.

---

## 9. Testing

**Swift unit tests** (`MacHost/Tests/`):
- `penEvent` decode: valid frame → correct `PenSample`; truncated frame →
  buffered, not consumed; oversized pointer values → rejected.
- Phase state machine: every `down` is eventually matched by an `up`; a
  `cancel` mid-stroke releases the button; two consecutive `down`s release the
  first.

**Kotlin unit tests** (`AndroidClient/app/src/test/`):
- `MotionEvent` → `PenSample` mapping including historical samples.
- Tilt conversion against hand-computed values, including the poles
  (tilt = 0 → tiltX = tiltY = 0).
- Encoder produces exactly 23 bytes with correct field offsets.

**Manual, on hardware** — the part that cannot be automated:
- Pressure ramp produces a visibly tapering stroke.
- Tilt in each of four directions moves the brush the expected way (validates
  sign conventions).
- Unplugging USB mid-stroke does not leave a stuck button.
- Old-APK-against-new-host and vice versa both degrade to plain touch.

---

## 10. Out of scope

- Graded hover height (hardware reports binary proximity only).
- Palm rejection — Android already handles this at the digitizer level.
- Windows host support.
- Upstream PR submission.
