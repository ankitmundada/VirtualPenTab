import CoreGraphics

/// Builds the CGEvents that carry stylus data to macOS.
///
/// Split out of PenInjector so the field wiring can be unit-tested: constructing
/// a CGEvent and reading it back needs no Accessibility permission, only
/// *posting* does.
public enum PenEventFactory {

    /// Any stable non-zero id; apps use it to tell input devices apart.
    public static let defaultDeviceID: Int64 = 0x5350 // "SP"
    public static let systemTabletID: Int64 = 1

    // NX_TABLET_POINTER_* constants from IOKit's HID event headers.
    public static let pointerTypePen: Int64 = 1
    public static let pointerTypeEraser: Int64 = 3

    /// A mouse event carrying tablet data, the shape real Wacom hardware
    /// presents to AppKit.
    public static func makeMouseEvent(
        type: CGEventType,
        at point: CGPoint,
        button: CGMouseButton,
        sample: PenSample,
        source: CGEventSource?,
        deviceID: Int64 = defaultDeviceID,
        clickState: Int64? = nil
    ) -> CGEvent? {
        guard let event = CGEvent(mouseEventSource: source,
                                  mouseType: type,
                                  mouseCursorPosition: point,
                                  mouseButton: button) else { return nil }

        event.setIntegerValueField(.mouseEventSubtype,
                                   value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
        event.setIntegerValueField(.tabletEventDeviceID, value: deviceID)
        event.setDoubleValueField(.tabletEventPointPressure, value: Double(sample.pressure))
        event.setDoubleValueField(.tabletEventTiltX, value: Double(sample.tiltX))
        event.setDoubleValueField(.tabletEventTiltY, value: Double(sample.tiltY))

        // Critical, and easy to get wrong: apps read `NSEvent.pressure`, which
        // is backed by kCGMouseEventPressure — NOT by the tablet field above.
        // Left unset it defaults to 255, so every sample arrives as maximum
        // pressure and strokes come out at constant width even though the
        // tablet field carries the real value. Genuine hardware sets both.
        event.setDoubleValueField(.mouseEventPressure, value: Double(sample.pressure))

        // Without an explicit click state a synthesized down/up pair is not
        // recognised as a complete click, so a tap with the pen does nothing.
        if let clickState {
            event.setIntegerValueField(.mouseEventClickState, value: clickState)
        }

        return event
    }

    /// Proximity enter/exit — what makes apps switch into tablet mode.
    public static func makeProximityEvent(
        entering: Bool,
        eraser: Bool,
        source: CGEventSource?,
        deviceID: Int64 = defaultDeviceID
    ) -> CGEvent? {
        guard let event = CGEvent(source: source) else { return nil }
        event.type = .tabletProximity
        event.setIntegerValueField(.tabletProximityEventEnterProximity, value: entering ? 1 : 0)
        event.setIntegerValueField(.tabletProximityEventPointerType,
                                   value: eraser ? pointerTypeEraser : pointerTypePen)
        event.setIntegerValueField(.tabletProximityEventDeviceID, value: deviceID)
        event.setIntegerValueField(.tabletProximityEventSystemTabletID, value: systemTabletID)
        return event
    }
}
