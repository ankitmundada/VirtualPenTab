// PenSpike.app — standalone validator for synthetic tablet-event injection.
//
// Runs as its own bundled app so macOS attributes the Accessibility grant to
// THIS app rather than to whatever terminal launched it. Writes findings to a
// log file since a bundled app has nowhere to print.
//
// Safety: installs a CONSUMING event tap that recognises its own events by a
// magic deviceID and swallows them, so no synthetic click ever reaches a real
// application or the desktop.

import Cocoa

let LOG = ("~/Desktop/penspike-result.txt" as NSString).expandingTildeInPath
var lines: [String] = []

func log(_ s: String) {
    lines.append(s)
    try? lines.joined(separator: "\n").write(toFile: LOG, atomically: true, encoding: .utf8)
}

let MAGIC: Int64 = 0xBEEF
var captured: [(String, Double, Double, Double, Int64)] = []

func typeName(_ t: CGEventType) -> String {
    switch t {
    case .leftMouseDown:    return "leftMouseDown"
    case .leftMouseDragged: return "leftMouseDragged"
    case .leftMouseUp:      return "leftMouseUp"
    case .mouseMoved:       return "mouseMoved"
    case .tabletPointer:    return "tabletPointer"
    case .tabletProximity:  return "tabletProximity"
    default:                return "type\(t.rawValue)"
    }
}

log("PenSpike — synthetic tablet event validation")
log("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
log("")

// Prompt for Accessibility if we don't have it yet.
let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
let trusted = AXIsProcessTrustedWithOptions(opts)
log("AXIsProcessTrusted = \(trusted)")
if !trusted {
    log("")
    log("NOT TRUSTED YET. macOS should have shown a permission dialog.")
    log("Grant 'PenSpike' in System Settings > Privacy & Security > Accessibility,")
    log("then launch PenSpike.app again.")
    exit(1)
}

let mask: CGEventMask =
    (1 << CGEventType.leftMouseDown.rawValue) |
    (1 << CGEventType.leftMouseDragged.rawValue) |
    (1 << CGEventType.leftMouseUp.rawValue) |
    (1 << CGEventType.mouseMoved.rawValue) |
    (1 << CGEventType.tabletPointer.rawValue) |
    (1 << CGEventType.tabletProximity.rawValue)

let cb: CGEventTapCallBack = { _, type, event, _ in
    let dev = event.getIntegerValueField(.tabletEventDeviceID)
    let pdev = event.getIntegerValueField(.tabletProximityEventDeviceID)
    guard dev == MAGIC || pdev == MAGIC else {
        return Unmanaged.passUnretained(event) // real user input — pass through
    }
    captured.append((typeName(type),
                     event.getDoubleValueField(.tabletEventPointPressure),
                     event.getDoubleValueField(.tabletEventTiltX),
                     event.getDoubleValueField(.tabletEventTiltY),
                     event.getIntegerValueField(.mouseEventSubtype)))
    return nil // swallow — never reaches any app
}

guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                  place: .headInsertEventTap,
                                  options: .defaultTap,
                                  eventsOfInterest: mask,
                                  callback: cb,
                                  userInfo: nil) else {
    log("FAIL: consuming tap could not be created despite being trusted.")
    exit(2)
}
CFRunLoopAddSource(CFRunLoopGetCurrent(),
                   CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0),
                   .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
log("Consuming tap installed — synthetic events will be swallowed.")
log("")

let src = CGEventSource(stateID: .hidSystemState)
let pt = CGPoint(x: 500, y: 500)

func decorate(_ e: CGEvent, _ pressure: Double, _ tx: Double, _ ty: Double) {
    e.setIntegerValueField(.mouseEventSubtype, value: 1) // kCGEventMouseSubtypeTabletPoint
    e.setIntegerValueField(.tabletEventDeviceID, value: MAGIC)
    e.setDoubleValueField(.tabletEventPointPressure, value: pressure)
    e.setDoubleValueField(.tabletEventTiltX, value: tx)
    e.setDoubleValueField(.tabletEventTiltY, value: ty)
}

// Proximity enter — tells apps a pen is present.
if let p = CGEvent(source: src) {
    p.type = .tabletProximity
    p.setIntegerValueField(.tabletProximityEventEnterProximity, value: 1)
    p.setIntegerValueField(.tabletProximityEventPointerType, value: 1)
    p.setIntegerValueField(.tabletProximityEventDeviceID, value: MAGIC)
    p.post(tap: .cghidEventTap)
}

// A full stroke with graded pressure.
let steps: [(CGEventType, Double)] = [
    (.mouseMoved, 0.0), (.leftMouseDown, 0.10),
    (.leftMouseDragged, 0.45), (.leftMouseDragged, 0.90), (.leftMouseUp, 0.0),
]
for (i, s) in steps.enumerated() {
    if let e = CGEvent(mouseEventSource: src, mouseType: s.0,
                       mouseCursorPosition: CGPoint(x: pt.x + Double(i), y: pt.y),
                       mouseButton: .left) {
        decorate(e, s.1, -0.25, 0.5)
        e.post(tap: .cghidEventTap)
    }
}

// Native tabletPointer event type, for comparison.
if let tp = CGEvent(source: src) {
    tp.type = .tabletPointer
    tp.location = pt
    decorate(tp, 0.77, 0.3, -0.3)
    tp.post(tap: .cghidEventTap)
}

let deadline = Date().addingTimeInterval(2.5)
while Date() < deadline && captured.count < 6 {
    CFRunLoopRunInMode(.defaultMode, 0.05, true)
}

log("Recovered \(captured.count) event(s) from the HID system:")
for c in captured {
    log(String(format: "  %-17@ pressure=%.3f tilt=(%+.3f, %+.3f) subtype=%d",
               c.0 as NSString, c.1, c.2, c.3, c.4))
}
log("")

let delivered = captured.count > 0
let graded = Set(captured.map { String(format: "%.2f", $0.1) }).count >= 3
let tiltKept = captured.contains { abs($0.2 + 0.25) < 0.02 && abs($0.3 - 0.5) < 0.02 }
let subtypeKept = captured.contains { $0.4 == 1 }

log("VERDICT")
log("  events delivered through HID .......... \(delivered ? "YES" : "NO")")
log("  distinct pressure values preserved .... \(graded ? "YES" : "NO")")
log("  tiltX/tiltY preserved ................. \(tiltKept ? "YES" : "NO")")
log("  tabletPoint subtype preserved ......... \(subtypeKept ? "YES" : "NO")")
log("")
log(delivered && graded && tiltKept
    ? "=> Pen injection is VIABLE on this macOS version."
    : "=> Pen injection did NOT fully validate — see rows above.")
