import Foundation

/// The client's real panel geometry.
///
/// The host otherwise has no idea what it is driving: the virtual display
/// descriptor reports a *fabricated* physical size, because its PPI value is a
/// lever to push macOS past its ~200 PPI Retina-detection threshold rather
/// than an honest description of the tablet. Those two numbers must stay
/// separate — reporting a truthful PPI in the descriptor would disable HiDPI
/// on any panel under 200 PPI.
public struct PanelInfo: Equatable {
    public let widthPx: Int
    public let heightPx: Int
    public let widthMm: Int
    public let heightMm: Int
    public let refreshHz: Int

    public init(widthPx: Int, heightPx: Int, widthMm: Int, heightMm: Int, refreshHz: Int) {
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.widthMm = widthMm
        self.heightMm = heightMm
        self.refreshHz = refreshHz
    }

    public var diagonalInches: Double {
        (Double(widthMm * widthMm + heightMm * heightMm)).squareRoot() / 25.4
    }

    /// Physical pixel density of the panel itself.
    public var ppi: Double {
        let diag = diagonalInches
        guard diag > 0 else { return 0 }
        return (Double(widthPx * widthPx + heightPx * heightPx)).squareRoot() / diag
    }

    public var aspectRatio: Double {
        heightPx > 0 ? Double(widthPx) / Double(heightPx) : 0
    }

    /// How large UI drawn at `logicalWidth` points would appear on this panel.
    /// Lower is bigger. A 14" MacBook Pro sits at about 128.
    public func logicalPointsPerInch(logicalWidth: Int, logicalHeight: Int) -> Double {
        let diag = diagonalInches
        guard diag > 0 else { return 0 }
        let d = Double(logicalWidth * logicalWidth + logicalHeight * logicalHeight).squareRoot()
        return d / diag
    }
}

public enum PanelInfoError: Error, Equatable {
    case truncated
    case malformedPayload
    case implausibleGeometry
}

/// Codec for the `clientPanelInfo` wire message (type 15).
///
/// Every payload byte carries 7 data bits with the high bit set, the same
/// convention as `clientDecoderLimits` (type 11): a host that does not know
/// this message consumes unknown types one byte at a time, so payload bytes
/// must never collide with real message-type values. That makes this safe to
/// send unsolicited during the handshake.
///
/// Layout: `[type][w hi][w lo][h hi][h lo][mmW hi][mmW lo][mmH hi][mmH lo][hz hi][hz lo]`
public enum PanelInfoCodec {
    public static let messageType: UInt8 = 15
    public static let frameSize = 11
    static let fieldCount = 5
    static let maxFieldValue = 16383 // 14 bits

    public static func encode(_ info: PanelInfo) -> Data {
        var d = Data([messageType])
        for value in [info.widthPx, info.heightPx, info.widthMm, info.heightMm, info.refreshHz] {
            let clamped = min(max(value, 0), maxFieldValue)
            d.append(UInt8(0x80 | ((clamped >> 7) & 0x7F)))
            d.append(UInt8(0x80 | (clamped & 0x7F)))
        }
        return d
    }

    public static func decode(_ data: Data) throws -> PanelInfo {
        guard data.count >= frameSize else { throw PanelInfoError.truncated }
        let b = Array(data.prefix(frameSize))

        let payload = Array(b[1..<frameSize])
        guard payload.allSatisfy({ $0 & 0x80 != 0 }) else {
            throw PanelInfoError.malformedPayload
        }

        var fields: [Int] = []
        for i in 0..<fieldCount {
            let hi = Int(payload[i * 2] & 0x7F)
            let lo = Int(payload[i * 2 + 1] & 0x7F)
            fields.append((hi << 7) | lo)
        }

        let info = PanelInfo(widthPx: fields[0], heightPx: fields[1],
                             widthMm: fields[2], heightMm: fields[3],
                             refreshHz: fields[4])

        // A client reporting nonsense would poison every downstream
        // calculation, so reject rather than recommend from bad geometry.
        guard info.widthPx >= 256, info.heightPx >= 256,
              info.widthMm >= 20, info.heightMm >= 20,
              info.refreshHz >= 15, info.refreshHz <= 480 else {
            throw PanelInfoError.implausibleGeometry
        }
        return info
    }
}
