// Unit tests for PenCore, as a plain executable.
//
// XCTest ships only with full Xcode, and this checkout builds against the
// Command Line Tools, so the repo's existing XCTest suite cannot run here.
// This follows the pattern already used by CaptureTest/ and StreamTest/:
// a standalone runner that exits non-zero on failure.
//
//   swift run PenCodecTest

import Cocoa
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

// MARK: - Summary

print("")
if failures == 0 {
    print("PASS — \(checks) checks")
    exit(0)
} else {
    print("FAIL — \(failures) of \(checks) checks failed")
    exit(1)
}
