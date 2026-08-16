import Foundation

public enum PenDecodeError: Error, Equatable {
    case truncated
    case invalidPhase(UInt8)
    case nonFinite
}

/// Decoder for the `penEvent` wire message (type 14).
///
/// Layout, little-endian, 23 bytes total:
///
///     [0]      type = 14
///     [1]      phase    u8
///     [2]      buttons  u8   bit0 barrel1, bit1 barrel2, bit2 eraser
///     [3..6]   x        f32  0...1
///     [7..10]  y        f32  0...1
///     [11..14] pressure f32  0...1
///     [15..18] tiltX    f32  -1...1
///     [19..22] tiltY    f32  -1...1
///
/// Pen frames are only ever sent to a host that acknowledged `penEnabled`
/// (type 13), so this payload needs no high-bit escaping — see
/// docs/pen-support-design.md §5.
public enum PenEventCodec {
    public static let messageType: UInt8 = 14
    public static let frameSize = 23

    public static func decode(_ data: Data) throws -> PenSample {
        guard data.count >= frameSize else { throw PenDecodeError.truncated }
        let b = Array(data.prefix(frameSize))

        guard let phase = PenPhase(rawValue: b[1]) else {
            throw PenDecodeError.invalidPhase(b[1])
        }

        func f32(at offset: Int) -> Float {
            let bits = UInt32(b[offset])
                | UInt32(b[offset + 1]) << 8
                | UInt32(b[offset + 2]) << 16
                | UInt32(b[offset + 3]) << 24
            return Float(bitPattern: bits)
        }

        let x = f32(at: 3)
        let y = f32(at: 7)
        let pressure = f32(at: 11)
        let tiltX = f32(at: 15)
        let tiltY = f32(at: 19)

        // A NaN coordinate would poison CGPoint arithmetic downstream and can
        // park the cursor somewhere unrecoverable, so reject rather than clamp.
        guard x.isFinite, y.isFinite, pressure.isFinite, tiltX.isFinite, tiltY.isFinite else {
            throw PenDecodeError.nonFinite
        }

        // Clamp rather than reject: a stroke at the very edge of the digitizer
        // can land a hair outside range through float rounding, and dropping
        // those samples would visibly clip strokes at the screen border.
        return PenSample(
            phase: phase,
            buttons: PenButtons(rawValue: b[2]).intersection(.known),
            x: clamp(x, 0, 1),
            y: clamp(y, 0, 1),
            pressure: clamp(pressure, 0, 1),
            tiltX: clamp(tiltX, -1, 1),
            tiltY: clamp(tiltY, -1, 1)
        )
    }

    /// Encoder, used by the test harness to build round-trip fixtures.
    public static func encode(_ s: PenSample) -> Data {
        var d = Data([messageType, s.phase.rawValue, s.buttons.rawValue])
        for f in [s.x, s.y, s.pressure, s.tiltX, s.tiltY] {
            withUnsafeBytes(of: f.bitPattern.littleEndian) { d.append(contentsOf: $0) }
        }
        return d
    }
}

@inline(__always)
func clamp(_ v: Float, _ lo: Float, _ hi: Float) -> Float {
    min(max(v, lo), hi)
}
