import Foundation

/// Pages in the main window's sidebar.
///
/// Grouping is by intent rather than by subsystem: everything needed to get a
/// tablet showing a picture lives on one page, and the encoder knobs most
/// people never touch are behind Advanced.
enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
    case connect
    case display
    case input
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connect: return "Connect"
        case .display: return "Display"
        case .input: return "Input"
        case .advanced: return "Advanced"
        }
    }

    var subtitle: String {
        switch self {
        case .connect: return "Pair a tablet and check that everything is ready"
        case .display: return "Resolution, refresh rate and orientation"
        case .input: return "Touch gestures and stylus behaviour"
        case .advanced: return "Encoding, networking and startup"
        }
    }

    var icon: String {
        switch self {
        case .connect: return "bolt.horizontal.circle"
        case .display: return "display"
        case .input: return "hand.draw"
        case .advanced: return "gearshape.2"
        }
    }
}
