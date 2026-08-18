import Foundation

/// How large the macOS UI should appear on the tablet.
///
/// This is a preference, not a computed value. Viewing distance and eyesight
/// vary, and a tablet lying flat on a desk is much further from your eyes than
/// a laptop screen — so the "correct" answer differs per person even on
/// identical hardware. Targets are logical points per inch; lower means bigger
/// UI. A 14" MacBook Pro is about 128.
public enum UISizePreference: String, CaseIterable {
    case larger
    case balanced
    case moreSpace

    public var targetPointsPerInch: Double {
        switch self {
        case .larger: return 118
        case .balanced: return 138
        case .moreSpace: return 168
        }
    }
}

public enum LinkKind {
    case usb
    case wireless

    /// Usable throughput in megabits per second.
    ///
    /// Deliberately conservative estimates rather than measurements. The Pad 5
    /// class of device is USB 2.0: 480 Mbps on paper, ~240-320 Mbps in
    /// practice through adb. Wireless varies far more, so it is assumed worse.
    /// Replacing these with a real throughput probe is the obvious upgrade.
    public var usableMbps: Double {
        switch self {
        case .usb: return 250
        case .wireless: return 100
        }
    }
}

public struct DisplayRecommendation: Equatable {
    /// Logical resolution to configure — what macOS treats as the desktop size.
    public let width: Int
    public let height: Int
    public let hiDPI: Bool
    public let refreshHz: Int
    public let bitrateMbps: Int
    /// True when the streamed pixels land exactly on the panel's own pixels.
    public let pixelExact: Bool
    public let notes: [String]

    /// Pixels actually encoded and sent.
    public var streamWidth: Int { hiDPI ? width * 2 : width }
    public var streamHeight: Int { hiDPI ? height * 2 : height }
}

public enum DisplayAdvisor {

    /// Bits per pixel per frame used to size the bitrate cap.
    ///
    /// Screen content compresses far better than camera video, but text needs
    /// enough bits to stay crisp. Measured on a near-static handwriting page
    /// the encoder used vastly less than this (about 1300:1); the cap only has
    /// to cover busier content without exceeding the link.
    static let bitsPerPixelPerFrame = 0.1

    /// How far a whole-number scale may sit from the requested UI size before
    /// we give up pixel-exactness to honour the preference.
    static let snapTolerancePPI = 10.0

    public static func recommend(
        panel: PanelInfo,
        decoderMax: (width: Int, height: Int)?,
        link: LinkKind,
        preference: UISizePreference = .balanced
    ) -> DisplayRecommendation {
        var notes: [String] = []

        // Candidate scales. 2x is only meaningful on a dense panel; below the
        // Retina threshold macOS will not treat it as HiDPI anyway.
        let candidateScales = panel.ppi >= 200 ? [2, 1] : [1]

        var bestScale = 1
        var bestError = Double.greatestFiniteMagnitude
        for scale in candidateScales {
            let lw = panel.widthPx / scale
            let lh = panel.heightPx / scale
            let ppi = panel.logicalPointsPerInch(logicalWidth: lw, logicalHeight: lh)
            let error = abs(ppi - preference.targetPointsPerInch)
            if error < bestError {
                bestError = error
                bestScale = scale
            }
        }

        var logicalW = panel.widthPx / bestScale
        var logicalH = panel.heightPx / bestScale
        var hiDPI = bestScale == 2
        var pixelExact = true

        // If mapping the panel 1:1 lands far from the target, the UI would be
        // the wrong size. Trade pixel-exactness for legibility by choosing a
        // logical size that hits the target and letting the client scale.
        //
        // The tolerance is deliberately tight. A wide one silently swallows an
        // explicit preference: on a 276 ppi 11" panel the only whole-number
        // scale lands at 138 ppi, so anything above ~20 would make "Larger"
        // and "Balanced" produce identical output and ignore what the user
        // actually asked for.
        if bestError > snapTolerancePPI {
            let targetDiag = preference.targetPointsPerInch * panel.diagonalInches
            let aspect = panel.aspectRatio
            let w = (targetDiag / (1 + 1 / (aspect * aspect)).squareRoot()).rounded()
            let scaledW = Int((w / 2).rounded()) * 2 // keep even
            let scaledH = Int((Double(scaledW) / aspect).rounded() / 2) * 2
            if scaledW >= 640 && scaledH >= 480 {
                logicalW = scaledW
                logicalH = scaledH
                hiDPI = panel.ppi >= 200
                pixelExact = false
                notes.append("Not a whole-number scale of the panel — slightly softer, but correctly sized.")
            }
        }

        // Never ask for more pixels than the client can decode.
        if let maxSize = decoderMax {
            let streamW = hiDPI ? logicalW * 2 : logicalW
            let streamH = hiDPI ? logicalH * 2 : logicalH
            if streamW > maxSize.width || streamH > maxSize.height {
                if hiDPI {
                    hiDPI = false
                    pixelExact = false
                    notes.append("HiDPI disabled — exceeds the client's decoder limit.")
                } else {
                    notes.append("Clamped to the client's decoder limit.")
                    logicalW = min(logicalW, maxSize.width)
                    logicalH = min(logicalH, maxSize.height)
                    pixelExact = false
                }
            }
        }

        let refresh = min(panel.refreshHz, 120)

        let streamW = hiDPI ? logicalW * 2 : logicalW
        let streamH = hiDPI ? logicalH * 2 : logicalH
        let pixels = Double(streamW * streamH)
        let contentMbps = pixels * Double(refresh) * bitsPerPixelPerFrame / 1_000_000
        // Half the link, leaving headroom: keyframes are far larger than the
        // frames either side of them, so a cap at the average would stall.
        let linkCap = link.usableMbps * 0.5
        let bitrate = max(5, Int(min(contentMbps, linkCap).rounded()))
        if contentMbps > linkCap {
            notes.append("Bitrate capped by the \(link == .usb ? "USB" : "wireless") link budget.")
        }

        return DisplayRecommendation(
            width: logicalW,
            height: logicalH,
            hiDPI: hiDPI,
            refreshHz: refresh,
            bitrateMbps: bitrate,
            pixelExact: pixelExact,
            notes: notes
        )
    }
}
