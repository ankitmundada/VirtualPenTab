// Unit tests for PenCore, as a plain executable.
//
// XCTest ships only with full Xcode, and this checkout builds against the
// Command Line Tools, so the repo's existing XCTest suite cannot run here.
// This follows the pattern already used by CaptureTest/ and StreamTest/:
// a standalone runner that exits non-zero on failure.
//
//   swift run PenCodecTest

import Cocoa
import DisplayCore
import Foundation
import PenCore

// MARK: - Tiny harness

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if !condition {
        failures += 1
        print("  FAIL  \(label)")
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual != expected {
        failures += 1
        print("  FAIL  \(label): got \(actual), expected \(expected)")
    }
}

func checkClose(_ actual: Float, _ expected: Float, _ label: String, tol: Float = 1e-6) {
    checks += 1
    if !(abs(actual - expected) <= tol) {
        failures += 1
        print("  FAIL  \(label): got \(actual), expected \(expected)")
    }
}

func checkThrows(_ expected: PenDecodeError, _ label: String, _ body: () throws -> Void) {
    checks += 1
    do {
        try body()
        failures += 1
        print("  FAIL  \(label): expected throw \(expected), got success")
    } catch let e as PenDecodeError where e == expected {
        // pass
    } catch {
        failures += 1
        print("  FAIL  \(label): expected \(expected), got \(error)")
    }
}

func checkThrowsPanel(_ expected: PanelInfoError, _ label: String, _ body: () throws -> Void) {
    checks += 1
    do {
        try body()
        failures += 1
        print("  FAIL  \(label): expected throw \(expected), got success")
    } catch let e as PanelInfoError where e == expected {
        // pass
    } catch {
        failures += 1
        print("  FAIL  \(label): expected \(expected), got \(error)")
    }
}

func section(_ name: String) { print("\n\(name)") }

// MARK: - Fixture

/// A well-formed frame; each test overrides only the field it cares about.
func penFrame(
    type: UInt8 = 14,
    phase: UInt8 = 3,
    buttons: UInt8 = 0,
    x: Float = 0.25,
    y: Float = 0.75,
    pressure: Float = 0.5,
    tiltX: Float = -0.25,
    tiltY: Float = 0.5
) -> Data {
    var d = Data([type, phase, buttons])
    for f in [x, y, pressure, tiltX, tiltY] {
        withUnsafeBytes(of: f.bitPattern.littleEndian) { d.append(contentsOf: $0) }
    }
    return d
}

// MARK: - Tests

print("PenCore tests")

section("framing")
checkEqual(PenEventCodec.frameSize, 23, "frameSize is 23")
checkEqual(penFrame().count, 23, "fixture is 23 bytes")
checkEqual(PenEventCodec.messageType, 14, "message type is 14")

section("field decoding")
do {
    let s = try PenEventCodec.decode(penFrame(
        phase: 2, buttons: 0b011, x: 0.25, y: 0.75,
        pressure: 0.5, tiltX: -0.25, tiltY: 0.5))
    checkEqual(s.phase, .down, "phase")
    check(s.buttons.contains(.barrel1), "barrel1 set")
    check(s.buttons.contains(.barrel2), "barrel2 set")
    check(!s.buttons.contains(.eraser), "eraser clear")
    checkClose(s.x, 0.25, "x")
    checkClose(s.y, 0.75, "y")
    checkClose(s.pressure, 0.5, "pressure")
    checkClose(s.tiltX, -0.25, "tiltX")
    checkClose(s.tiltY, 0.5, "tiltY")
} catch {
    failures += 1
    print("  FAIL  field decoding threw \(error)")
}

section("all phases decode")
for (raw, expected) in PenPhase.allCases.enumerated() {
    do {
        let s = try PenEventCodec.decode(penFrame(phase: UInt8(raw)))
        checkEqual(s.phase, expected, "phase byte \(raw)")
    } catch {
        failures += 1
        print("  FAIL  phase byte \(raw) threw \(error)")
    }
}

section("eraser button")
if let s = try? PenEventCodec.decode(penFrame(buttons: 0b100)) {
    check(s.buttons.contains(.eraser), "eraser set")
    check(!s.buttons.contains(.barrel1), "barrel1 clear")
} else {
    failures += 1; print("  FAIL  eraser frame did not decode")
}

section("unknown button bits ignored")
if let s = try? PenEventCodec.decode(penFrame(buttons: 0b1111_1000)) {
    checkEqual(s.buttons.rawValue, 0, "undefined bits stripped")
} else {
    failures += 1; print("  FAIL  frame with unknown bits did not decode")
}

section("rejection")
checkThrows(.truncated, "truncated frame") {
    _ = try PenEventCodec.decode(penFrame().dropLast())
}
checkThrows(.invalidPhase(7), "unknown phase 7") {
    _ = try PenEventCodec.decode(penFrame(phase: 7))
}
for bad in [Float.nan, .infinity, -.infinity] {
    checkThrows(.nonFinite, "non-finite pressure \(bad)") {
        _ = try PenEventCodec.decode(penFrame(pressure: bad))
    }
    checkThrows(.nonFinite, "non-finite x \(bad)") {
        _ = try PenEventCodec.decode(penFrame(x: bad))
    }
}

section("clamping")
if let s = try? PenEventCodec.decode(penFrame(x: -0.01, y: 1.02, pressure: 1.5)) {
    checkClose(s.x, 0.0, "x clamped low")
    checkClose(s.y, 1.0, "y clamped high")
    checkClose(s.pressure, 1.0, "pressure clamped high")
} else {
    failures += 1; print("  FAIL  out-of-range frame did not decode")
}
if let s = try? PenEventCodec.decode(penFrame(tiltX: -3.0, tiltY: 2.5)) {
    checkClose(s.tiltX, -1.0, "tiltX clamped low")
    checkClose(s.tiltY, 1.0, "tiltY clamped high")
} else {
    failures += 1; print("  FAIL  out-of-range tilt frame did not decode")
}

section("contact classification")
check(PenPhase.down.isContact, "down is contact")
check(PenPhase.move.isContact, "move is contact")
check(!PenPhase.hoverEnter.isContact, "hoverEnter is not contact")
check(!PenPhase.hoverMove.isContact, "hoverMove is not contact")
check(!PenPhase.up.isContact, "up is not contact")
check(!PenPhase.hoverExit.isContact, "hoverExit is not contact")
check(!PenPhase.cancel.isContact, "cancel is not contact")

section("encode/decode round trip")
let original = PenSample(phase: .move, buttons: [.barrel1, .eraser],
                         x: 0.125, y: 0.875, pressure: 0.375,
                         tiltX: -0.5, tiltY: 0.25)
if let back = try? PenEventCodec.decode(PenEventCodec.encode(original)) {
    checkEqual(back, original, "round trip preserves sample")
} else {
    failures += 1; print("  FAIL  round trip did not decode")
}

// MARK: - Event construction
//
// Regression guard for the bug that made stylus pressure look completely
// broken: apps read NSEvent.pressure, which is backed by kCGMouseEventPressure,
// NOT by kCGTabletEventPointPressure. Setting only the tablet field leaves
// mouseEventPressure at its default of 255, so every sample reads as full
// pressure and strokes come out at constant width.
//
// Building and reading back a CGEvent needs no Accessibility permission —
// only posting does — so this runs anywhere.

section("event construction: pressure reaches NSEvent")
for value in [Float(0.0), 0.25, 0.5, 0.75, 1.0] {
    let s = PenSample(phase: .move, buttons: [], x: 0.5, y: 0.5,
                      pressure: value, tiltX: 0, tiltY: 0)
    guard let event = PenEventFactory.makeMouseEvent(
        type: .leftMouseDragged,
        at: CGPoint(x: 300, y: 300),
        button: .left,
        sample: s,
        source: CGEventSource(stateID: .hidSystemState)
    ) else {
        failures += 1
        print("  FAIL  could not build event for pressure \(value)")
        continue
    }

    checkClose(Float(event.getDoubleValueField(.tabletEventPointPressure)), value,
               "tablet field at \(value)", tol: 1e-3)
    // The one that actually matters to applications.
    checkClose(Float(NSEvent(cgEvent: event)?.pressure ?? -1), value,
               "NSEvent.pressure at \(value)", tol: 1e-2)
}

section("event construction: tilt and subtype")
do {
    let s = PenSample(phase: .move, buttons: [], x: 0.5, y: 0.5,
                      pressure: 0.5, tiltX: -0.25, tiltY: 0.5)
    if let e = PenEventFactory.makeMouseEvent(
        type: .leftMouseDragged, at: CGPoint(x: 300, y: 300), button: .left,
        sample: s, source: CGEventSource(stateID: .hidSystemState)) {
        // CGEvent stores tilt as fixed point, so a round trip lands within
        // ~2e-5 of the value set rather than exactly on it. Well below the
        // ~1 degree resolution any real digitizer reports.
        let quantization: Float = 1e-3
        checkClose(Float(e.getDoubleValueField(.tabletEventTiltX)), -0.25, "tiltX field", tol: quantization)
        checkClose(Float(e.getDoubleValueField(.tabletEventTiltY)), 0.5, "tiltY field", tol: quantization)
        checkEqual(e.getIntegerValueField(.mouseEventSubtype),
                   Int64(CGEventMouseSubtype.tabletPoint.rawValue), "tabletPoint subtype")
        let ns = NSEvent(cgEvent: e)
        checkClose(Float(ns?.tilt.x ?? -9), -0.25, "NSEvent tilt.x", tol: quantization)
        checkClose(Float(ns?.tilt.y ?? -9), 0.5, "NSEvent tilt.y", tol: quantization)
    } else {
        failures += 1; print("  FAIL  could not build tilt event")
    }
}

section("event construction: proximity")
do {
    let src = CGEventSource(stateID: .hidSystemState)
    if let enter = PenEventFactory.makeProximityEvent(entering: true, eraser: false, source: src) {
        checkEqual(enter.getIntegerValueField(.tabletProximityEventEnterProximity), 1, "enter flag")
        checkEqual(enter.getIntegerValueField(.tabletProximityEventPointerType),
                   PenEventFactory.pointerTypePen, "pen pointer type")
    } else {
        failures += 1; print("  FAIL  could not build proximity enter")
    }
    if let exit = PenEventFactory.makeProximityEvent(entering: false, eraser: true, source: src) {
        checkEqual(exit.getIntegerValueField(.tabletProximityEventEnterProximity), 0, "exit flag")
        checkEqual(exit.getIntegerValueField(.tabletProximityEventPointerType),
                   PenEventFactory.pointerTypeEraser, "eraser pointer type")
    } else {
        failures += 1; print("  FAIL  could not build proximity exit")
    }
}

// MARK: - Panel info
//
// Geometry is the Xiaomi Pad 5 the pen work was validated on: 2560x1600
// across a 10.95 inch panel, 120 Hz.

let padFive = PanelInfo(widthPx: 2560, heightPx: 1600,
                        widthMm: 236, heightMm: 147, refreshHz: 120)

section("panel info: derived geometry")
checkClose(Float(padFive.diagonalInches), 10.95, "diagonal inches", tol: 0.1)
checkClose(Float(padFive.ppi), 276, "panel ppi", tol: 2)
checkClose(Float(padFive.aspectRatio), 1.6, "aspect ratio", tol: 0.01)
checkClose(Float(padFive.logicalPointsPerInch(logicalWidth: 1280, logicalHeight: 800)),
           138, "logical ppi at 1280x800", tol: 2)
checkClose(Float(padFive.logicalPointsPerInch(logicalWidth: 1680, logicalHeight: 1050)),
           181, "logical ppi at 1680x1050", tol: 2)

section("panel info: codec round trip")
do {
    let encoded = PanelInfoCodec.encode(padFive)
    checkEqual(encoded.count, PanelInfoCodec.frameSize, "frame is 11 bytes")
    checkEqual(encoded.first, PanelInfoCodec.messageType, "type byte is 15")
    // Every payload byte must have the high bit set so a host that does not
    // know this message skips it one byte at a time without desyncing.
    check(encoded.dropFirst().allSatisfy { $0 & 0x80 != 0 }, "payload bytes are high-bit safe")
    if let back = try? PanelInfoCodec.decode(encoded) {
        checkEqual(back, padFive, "round trip preserves geometry")
    } else {
        failures += 1; print("  FAIL  panel info did not round trip")
    }
}

section("panel info: rejection")
checkThrowsPanel(.truncated, "truncated frame") {
    _ = try PanelInfoCodec.decode(PanelInfoCodec.encode(padFive).dropLast())
}
checkThrowsPanel(.malformedPayload, "payload without high bits") {
    var bad = PanelInfoCodec.encode(padFive)
    bad[3] = 0x01
    _ = try PanelInfoCodec.decode(bad)
}
checkThrowsPanel(.implausibleGeometry, "zero-size panel") {
    _ = try PanelInfoCodec.decode(PanelInfoCodec.encode(
        PanelInfo(widthPx: 10, heightPx: 10, widthMm: 1, heightMm: 1, refreshHz: 60)))
}

// MARK: - Recommendation

section("advisor: dense panel gets HiDPI at half the pixels")
do {
    let r = DisplayAdvisor.recommend(panel: padFive,
                                     decoderMax: (8192, 4320),
                                     link: .usb,
                                     preference: .balanced)
    checkEqual(r.width, 1280, "logical width")
    checkEqual(r.height, 800, "logical height")
    check(r.hiDPI, "HiDPI enabled on a 276 ppi panel")
    check(r.pixelExact, "maps 1:1 onto the panel")
    checkEqual(r.streamWidth, 2560, "streams at panel width")
    checkEqual(r.refreshHz, 120, "refresh follows the panel")
    check(r.bitrateMbps > 0, "bitrate is positive")
}

section("advisor: preference is never silently ignored")
do {
    // Regression: a wide snap tolerance made Larger and Balanced identical on
    // this panel, discarding an explicit choice without saying so.
    let bigger = DisplayAdvisor.recommend(panel: padFive, decoderMax: nil,
                                          link: .usb, preference: .larger)
    let balanced = DisplayAdvisor.recommend(panel: padFive, decoderMax: nil,
                                            link: .usb, preference: .balanced)
    let roomier = DisplayAdvisor.recommend(panel: padFive, decoderMax: nil,
                                           link: .usb, preference: .moreSpace)

    checkEqual(balanced.width, 1280, "balanced stays pixel-exact")
    check(balanced.pixelExact, "balanced maps 1:1")
    check(bigger.width < balanced.width, "larger really is larger")
    check(roomier.width > balanced.width, "more space really is roomier")

    // Each should land close to the size it promised.
    for (label, r, pref) in [("larger", bigger, UISizePreference.larger),
                             ("balanced", balanced, UISizePreference.balanced),
                             ("moreSpace", roomier, UISizePreference.moreSpace)] {
        let actual = padFive.logicalPointsPerInch(logicalWidth: r.width, logicalHeight: r.height)
        checkClose(Float(actual), Float(pref.targetPointsPerInch),
                   "\(label) hits its target ppi", tol: 12)
    }

    // Anything not pixel-exact must say so rather than quietly degrade.
    check(!bigger.pixelExact && !bigger.notes.isEmpty, "larger explains the trade-off")
    check(!roomier.pixelExact && !roomier.notes.isEmpty, "moreSpace explains the trade-off")
}

section("advisor: low-density panel never claims HiDPI")
do {
    // A budget 10 inch 1280x800 tablet: 151 ppi, below the Retina threshold.
    let budget = PanelInfo(widthPx: 1280, heightPx: 800,
                           widthMm: 216, heightMm: 135, refreshHz: 60)
    check(budget.ppi < 200, "panel is below the Retina threshold")
    let r = DisplayAdvisor.recommend(panel: budget, decoderMax: nil, link: .usb)
    check(!r.hiDPI, "HiDPI stays off")
    checkEqual(r.refreshHz, 60, "refresh follows the panel")
}

section("advisor: decoder limit is respected")
do {
    let r = DisplayAdvisor.recommend(panel: padFive,
                                     decoderMax: (1920, 1080),
                                     link: .usb)
    check(r.streamWidth <= 1920, "stream width within decoder limit")
    check(r.streamHeight <= 1080, "stream height within decoder limit")
    check(!r.notes.isEmpty, "explains the clamp")
}

section("advisor: wireless gets a smaller bitrate budget")
do {
    let wired = DisplayAdvisor.recommend(panel: padFive, decoderMax: nil, link: .usb)
    let air = DisplayAdvisor.recommend(panel: padFive, decoderMax: nil, link: .wireless)
    check(air.bitrateMbps <= wired.bitrateMbps, "wireless cap is not higher")
    check(air.bitrateMbps >= 5, "still a usable floor")
}

// MARK: - Bitrate controller

section("bitrate controller: starts at the ceiling")
do {
    let c = BitrateController(ceilingMbps: 40)
    checkEqual(c.currentMbps, 40, "starts at ceiling")
    check(!c.isThrottled, "not throttled initially")
}

section("bitrate controller: backs off under congestion")
do {
    var c = BitrateController(ceilingMbps: 40)
    let over = BitrateController.congestionThresholdBytes(forMbps: 40) + 1
    let first = c.observe(inFlightBytes: over)
    check(first < 40, "drops below ceiling")
    check(c.isThrottled, "reports throttled")
    let second = c.observe(inFlightBytes: over)
    check(second < first, "keeps dropping while congested")
}

section("bitrate controller: never below the floor")
do {
    var c = BitrateController(ceilingMbps: 40, floorMbps: 5)
    for _ in 0..<50 { c.observe(inFlightBytes: 100 * 1024 * 1024) }
    checkEqual(c.currentMbps, 5, "clamps at floor")
}

section("bitrate controller: recovers only after sustained calm")
do {
    var c = BitrateController(ceilingMbps: 40, floorMbps: 5, recoveryPatience: 3)
    c.observe(inFlightBytes: 100 * 1024 * 1024)
    let low = c.currentMbps
    // Fewer calm samples than the patience threshold must not raise it.
    c.observe(inFlightBytes: 0)
    c.observe(inFlightBytes: 0)
    checkEqual(c.currentMbps, low, "no premature recovery")
    c.observe(inFlightBytes: 0)
    check(c.currentMbps > low, "recovers after patience is met")
}

section("bitrate controller: recovery stops at the ceiling")
do {
    var c = BitrateController(ceilingMbps: 40, floorMbps: 5, recoveryPatience: 1)
    c.observe(inFlightBytes: 100 * 1024 * 1024)
    for _ in 0..<200 { c.observe(inFlightBytes: 0) }
    checkEqual(c.currentMbps, 40, "returns to ceiling, no overshoot")
    check(!c.isThrottled, "no longer throttled")
}

section("bitrate controller: ceiling changes are respected")
do {
    var c = BitrateController(ceilingMbps: 40)
    c.updateCeiling(12)
    checkEqual(c.currentMbps, 12, "current pulled down to new ceiling")
    c.updateCeiling(2)
    checkEqual(c.currentMbps, 5, "floor still wins over a silly ceiling")
}

section("bitrate controller: threshold scales with bitrate")
do {
    let low = BitrateController.congestionThresholdBytes(forMbps: 5)
    let high = BitrateController.congestionThresholdBytes(forMbps: 400)
    check(high > low, "higher bitrate tolerates a larger backlog")
    checkEqual(low, 64 * 1024, "small bitrates get the 64 KB floor")
}

// MARK: - Summary

print("")
if failures == 0 {
    print("PASS — \(checks) checks")
    exit(0)
} else {
    print("FAIL — \(failures) of \(checks) checks failed")
    exit(1)
}
