import Foundation

/// Adapts bitrate to what the link is actually carrying.
///
/// The send path queues frames to the socket without bound, so a link that
/// cannot keep up does not drop frames — the socket buffer absorbs the excess
/// and latency grows without limit. Bufferbloat, in other words: the picture
/// stays intact and gets steadily later, which is worse than a lower bitrate.
///
/// The congestion signal is bytes in flight: handed to the transport but not
/// yet completed. That is a local measurement needing no protocol support, and
/// unlike a one-shot bandwidth probe it tracks a link whose capacity changes —
/// which is the normal case for Wi-Fi.
///
/// Additive increase, multiplicative decrease, the same shape TCP uses: back
/// off fast when it hurts, recover slowly so a brief hiccup does not park you
/// at the floor.
public struct BitrateController: Equatable {

    /// Upper bound — the advisor's recommendation, or the manual setting.
    public var ceilingMbps: Int
    /// Never go below this; a picture this poor is not worth having.
    public let floorMbps: Int
    /// Consecutive uncongested samples required before stepping back up.
    public let recoveryPatience: Int

    public private(set) var currentMbps: Int
    private var calmStreak = 0

    public init(ceilingMbps: Int, floorMbps: Int = 5, recoveryPatience: Int = 5) {
        self.ceilingMbps = max(floorMbps, ceilingMbps)
        self.floorMbps = floorMbps
        self.recoveryPatience = recoveryPatience
        self.currentMbps = self.ceilingMbps
    }

    /// How large a *persistent* backlog counts as congestion.
    ///
    /// Applied to the trough — the low-water mark of the send queue — not the
    /// peak. A queue that drains to near zero between frames is healthy no
    /// matter how big the peaks are, so this only needs to be above the noise
    /// floor rather than above a keyframe.
    ///
    /// Measured on Wi-Fi carrying 2560x1600 video: an uncongested link troughs
    /// at essentially zero, so 32 KB is comfortably clear of normal operation
    /// while still catching a queue that is failing to empty.
    public static func congestionThresholdBytes(forMbps mbps: Int) -> Int {
        max(32 * 1024, mbps * 1_000_000 / 8 / 100)
    }

    /// Feeds one observation and returns the bitrate to use.
    @discardableResult
    public mutating func observe(inFlightBytes: Int) -> Int {
        let threshold = Self.congestionThresholdBytes(forMbps: currentMbps)

        if inFlightBytes > threshold {
            calmStreak = 0
            // 0.7 rather than TCP's 0.5: video quality degrades visibly, and
            // overshooting downward costs more here than converging slowly.
            currentMbps = max(floorMbps, Int(Double(currentMbps) * 0.7))
        } else {
            calmStreak += 1
            if calmStreak >= recoveryPatience {
                calmStreak = 0
                // Additive, a tenth of the ceiling at a time.
                currentMbps = min(ceilingMbps, currentMbps + max(1, ceilingMbps / 10))
            }
        }
        return currentMbps
    }

    /// Raises or lowers the ceiling, keeping the current value inside it.
    public mutating func updateCeiling(_ mbps: Int) {
        ceilingMbps = max(floorMbps, mbps)
        currentMbps = min(currentMbps, ceilingMbps)
    }

    /// True when the link is forcing us below what was asked for.
    public var isThrottled: Bool { currentMbps < ceilingMbps }
}
