import Cocoa
import PenCore

/// Turns decoded stylus samples into macOS tablet events.
///
/// Deliberately separate from AppDelegate's gesture state machine. That machine
/// emulates a *trackpad* — tap, long press, scroll, pinch, momentum — while a
/// pen is direct absolute pointing. Routing a stylus through it is exactly why
/// drawing does not work today: a stroke that travels further than
/// `tapMaxDistance` before `longPressTime` elapses is reinterpreted as a scroll
/// (issue #45).
///
/// Verified on macOS 26.3.1 that graded pressure, two-axis tilt and the
/// tabletPoint subtype all survive `CGEvent.post` — see
/// docs/pen-support-design.md §4. Posting the tablet data on ordinary mouse
/// events with the tabletPoint subtype is how real Wacom hardware surfaces to
/// AppKit, which is why apps read pressure from it.
final class PenInjector {

    private let eventSource = CGEventSource(stateID: .hidSystemState)

    private var inProximity = false
    private var heldButton: CGMouseButton?
    private var lastPoint: CGPoint = .zero

    /// True while a mouse button is held down on behalf of the pen.
    var isStrokeActive: Bool { heldButton != nil }

    // MARK: - Entry point

    func handle(_ sample: PenSample, in bounds: CGRect) {
        let point = CGPoint(
            x: bounds.origin.x + CGFloat(sample.x) * bounds.width,
            y: bounds.origin.y + CGFloat(sample.y) * bounds.height
        )
        lastPoint = point

        switch sample.phase {
        case .hoverEnter:
            enterProximity(eraser: sample.buttons.contains(.eraser))

        case .hoverMove:
            // A pen can reach the digitizer's range without us having seen an
            // enter event (app launched with the pen already hovering).
            enterProximity(eraser: sample.buttons.contains(.eraser))
            post(.mouseMoved, at: point, button: .left, sample: sample)

        case .down:
            enterProximity(eraser: sample.buttons.contains(.eraser))
            // A second down without an intervening up would otherwise leave
            // the first button stuck held.
            releaseHeldButton(at: point, sample: sample)
            let button: CGMouseButton = sample.buttons.contains(.barrel1) ? .right : .left
            heldButton = button
            post(downType(for: button), at: point, button: button, sample: sample, clickState: 1)

        case .move:
            if let button = heldButton {
                post(dragType(for: button), at: point, button: button, sample: sample)
            } else {
                // Contact without a preceding down — treat as hover so the
                // cursor still tracks rather than dropping the sample.
                post(.mouseMoved, at: point, button: .left, sample: sample)
            }

        case .up:
            releaseHeldButton(at: point, sample: sample)

        case .hoverExit:
            releaseHeldButton(at: point, sample: sample)
            exitProximity()

        case .cancel:
            releaseHeldButton(at: point, sample: sample)
            exitProximity()
        }
    }

    // MARK: - Teardown safety
    //
    // A pen makes a held mouse button the normal state of every stroke rather
    // than the rare long-press case, so any path that can end a stroke without
    // its matching up MUST come through here. Otherwise unplugging USB
    // mid-stroke leaves the left button held down system-wide.
    // (Same failure mode PR #46 fixes for the touch path.)

    /// Releases any held button and drops out of proximity. Safe to call when
    /// nothing is held.
    func reset() {
        if heldButton != nil || inProximity {
            let sample = PenSample(phase: .cancel, buttons: [], x: 0, y: 0,
                                   pressure: 0, tiltX: 0, tiltY: 0)
            releaseHeldButton(at: lastPoint, sample: sample)
            exitProximity()
        }
    }

    private func releaseHeldButton(at point: CGPoint, sample: PenSample) {
        guard let button = heldButton else { return }
        heldButton = nil
        post(upType(for: button), at: point, button: button, sample: sample, clickState: 1)
    }

    // MARK: - Proximity

    private func enterProximity(eraser: Bool) {
        guard !inProximity else { return }
        inProximity = true
        postProximity(entering: true, eraser: eraser)
    }

    private func exitProximity() {
        guard inProximity else { return }
        inProximity = false
        postProximity(entering: false, eraser: false)
    }

    private func postProximity(entering: Bool, eraser: Bool) {
        PenEventFactory.makeProximityEvent(entering: entering,
                                           eraser: eraser,
                                           source: eventSource)?
            .post(tap: .cghidEventTap)
    }

    // MARK: - Event construction

    private func post(
        _ type: CGEventType,
        at point: CGPoint,
        button: CGMouseButton,
        sample: PenSample,
        clickState: Int64? = nil
    ) {
        PenEventFactory.makeMouseEvent(type: type,
                                       at: point,
                                       button: button,
                                       sample: sample,
                                       source: eventSource,
                                       clickState: clickState)?
            .post(tap: .cghidEventTap)
    }

    private func downType(for button: CGMouseButton) -> CGEventType {
        button == .right ? .rightMouseDown : .leftMouseDown
    }

    private func dragType(for button: CGMouseButton) -> CGEventType {
        button == .right ? .rightMouseDragged : .leftMouseDragged
    }

    private func upType(for button: CGMouseButton) -> CGEventType {
        button == .right ? .rightMouseUp : .leftMouseUp
    }
}
