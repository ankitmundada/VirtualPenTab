# Stylus Support — Setup and Troubleshooting

Turns a tablet stylus into a pressure- and tilt-sensitive graphics tablet for
macOS. Drawing apps see a real pen, not a mouse click.

Validated on **Xiaomi Pad 5 + Xiaomi Smart Pen → macOS 26.3.1**, over USB.

---

## What you get

| Feature | Supported | Notes |
|---|---|---|
| Pressure | Yes | 4096 levels on the Pad 5 digitizer |
| Tilt | Yes | Two independent axes, ±60° |
| Hover | Yes | In-range/out-of-range only |
| Barrel button 1 | Yes | Right-click while drawing |
| Barrel button 2 | Yes | Reported to the host |
| Eraser tip | Yes | Sent as an eraser pointer type |
| Hover *height* | No | Hardware reports proximity as a binary flag only |

Apps that read macOS tablet events — Photoshop, Affinity, Blender, Procreate
Dreams, Freeform, most creative software — pick up pressure and tilt
automatically. Apps that only read mouse events still work; they just ignore
the extra data.

---

## Setup

### 1. macOS permissions

Two are required, both under **System Settings → Privacy & Security**:

- **Screen Recording** — for the virtual display (already needed by SideScreen).
- **Accessibility** — for injecting pen events.

Accessibility is the one people miss. Without it `CGEvent.post` silently does
nothing: the stream looks perfect and the pen does absolutely nothing. The app
logs `⚠️ Accessibility not granted - pen input ignored` once per session when
this happens.

### 1b. Stop macOS asking every rebuild

If you build from source, an ad-hoc signature (`codesign --sign -`) has no
certificate, so TCC identifies the app by its **cdhash** — a hash of the binary.
Every rebuild changes it, macOS concludes it is a different app, and both
permissions have to be granted again.

A free self-signed certificate fixes this permanently:

1. Open **Keychain Access** → menu **Keychain Access → Certificate Assistant →
   Create a Certificate…**
2. Name: **SideScreen Local Signing**
3. Identity Type: **Self Signed Root**
4. Certificate Type: **Code Signing**
5. Create, then quit Keychain Access.

`build_mac.sh` picks it up automatically on the next build — it looks for that
name and falls back to ad-hoc signing if it is missing. Override the name with
`SIDESCREEN_SIGN_ID` if you already have a Developer ID certificate.

You do **not** need to mark the certificate as trusted. A self-signed
certificate reports `CSSMERR_TP_NOT_TRUSTED` and is hidden by
`security find-identity -v`, but it signs perfectly well — trust governs
signature *verification*, not creation. The resulting designated requirement is
`identifier "com.sidescreen.app" and certificate leaf = H"..."`, and both halves
are stable across rebuilds, which is all TCC needs.

Grant Accessibility and Screen Recording once more after the first
certificate-signed build (the identity has genuinely changed), and they will
stick from then on.

### 2. Turn stylus input on

**Settings → Touch Control → Stylus Input.** On by default.

"Enable Touch Input" must also be on — stylus input is gated behind it, since
turning off all tablet input should turn off *all* tablet input.

### 3. Install the Android client

On Xiaomi/Redmi devices running MIUI or HyperOS, `adb install` usually fails
first time with:

```
INSTALL_FAILED_USER_RESTRICTED: Install canceled by user
```

This is MIUI, not the app. In **Developer options**, enable:

- **Install via USB**
- **USB debugging (Security settings)**

MIUI frequently requires a signed-in Mi account (sometimes with a SIM present)
before it will let you enable "Install via USB". If it stays greyed out, use
**Wireless debugging** and pair over Wi-Fi instead — that path has no such
restriction.

---

## Verifying it works

Quickest check that does not need creative software:

1. Connect the tablet and start the host.
2. Open **Freeform** on the virtual display, pick the pen tool.
3. Draw a slow stroke, pressing harder partway through.

A working setup gives a stroke that visibly thickens where you pressed. A
stroke of constant width means pressure isn't arriving — see below.

---

## Troubleshooting

**The pen moves the cursor but won't draw.**
Stylus input is off, or the host never acked it. Check the host log for
`Sent penEnabled — stylus input active` and the client log for
`🖊️ Stylus input enabled by host`. If neither appears, the two builds
disagree about the protocol — rebuild and reinstall both sides.

**Nothing happens at all when the pen touches the screen.**
Accessibility permission. See step 1. Note that granting it to a terminal is
not enough if you launched the app some other way — the permission attaches to
the application that actually posts the events.

**Strokes are drawn but pressure is constant.**
The app you're drawing in may not read tablet events. Confirm in a known-good
app such as Freeform before digging further.

**Strokes look angular / polygonal.**
Expected only if historical-sample batching regressed. `PenInput.emitWithHistory`
replays every batched sample; if it is skipped, the pen's ~240 Hz stream gets
decimated to the 60–120 Hz vsync rate.

**Tilt behaves backwards in one axis.**
Sign conventions differ between digitizers. The conversion lives in
`PenTilt.toCartesian` (`PenEvent.kt`) — negate the offending component there
and add a case to `PenTiltTest`.

**A mouse button is stuck down after unplugging.**
Should not happen: `PenInjector.reset()` runs on client disconnect, server
stop, and the stylus toggle. If you can reproduce it, note what ended the
stroke — that's a missing teardown path.

---

## How it works

```
Xiaomi Smart Pen
      │  MotionEvent (pressure, AXIS_TILT, orientation, buttonState)
      ▼
PenInput.kt ──────── replays historical samples, polar tilt → tiltX/tiltY
      │  PenSample
      ▼
StreamClient.sendPen ─── 23-byte frame, wire type 14
      │  TCP over USB (adb reverse) or Wi-Fi
      ▼
StreamingServer ──── PenEventCodec.decode → PenSample
      │
      ▼
PenInjector.swift ── CGEvent mouse events + tabletPoint subtype
      │              carrying pressure, tiltX, tiltY, proximity
      ▼
   macOS apps
```

Pen frames are only sent after the host acknowledges support, so a client and
host built from different revisions fall back to plain touch instead of
corrupting the input stream. Design rationale and measurements are in
[pen-support-design.md](pen-support-design.md).

`tools/penspike/` contains a standalone validator that proves synthetic tablet
events survive the HID system on a given macOS version, without needing the
tablet connected.
