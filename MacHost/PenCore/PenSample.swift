import Foundation

/// Where the pen is in a stroke.
///
/// Kept deliberately explicit rather than derived from pressure: a stylus can
/// report non-zero pressure while still hovering on some digitizers, so the
/// client tells us the phase instead of us guessing from the numbers.
public enum PenPhase: UInt8, Equatable, CaseIterable {
    case hoverEnter = 0
    case hoverMove  = 1
    case down       = 2
    case move       = 3
    case up         = 4
    case hoverExit  = 5
    case cancel     = 6

    /// True while the tip is touching the glass — i.e. a mouse button should
    /// be held down. Drives PenInjector's stroke bookkeeping.
    public var isContact: Bool {
        self == .down || self == .move
    }
}

public struct PenButtons: OptionSet, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let barrel1 = PenButtons(rawValue: 1 << 0)
    public static let barrel2 = PenButtons(rawValue: 1 << 1)
    public static let eraser  = PenButtons(rawValue: 1 << 2)

    /// Bits the wire format currently defines; anything else is ignored so a
    /// newer client adding a button cannot confuse an older host.
    public static let known: PenButtons = [.barrel1, .barrel2, .eraser]
}

/// One decoded pen sample. Coordinates are normalized 0...1 against the
/// virtual display, matching the convention the touch path already uses.
public struct PenSample: Equatable {
    public let phase: PenPhase
    public let buttons: PenButtons
    public let x: Float
    public let y: Float
    /// 0...1. Always 0 for hover phases.
    public let pressure: Float
    /// -1...1, independent axes. Positive tiltX leans right, positive tiltY
    /// leans toward the user, matching macOS tabletEventTiltX/Y.
    public let tiltX: Float
    public let tiltY: Float

    public init(
        phase: PenPhase,
        buttons: PenButtons,
        x: Float,
        y: Float,
        pressure: Float,
        tiltX: Float,
        tiltY: Float
    ) {
        self.phase = phase
        self.buttons = buttons
        self.x = x
        self.y = y
        self.pressure = pressure
        self.tiltX = tiltX
        self.tiltY = tiltY
    }
}
