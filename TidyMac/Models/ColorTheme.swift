import SwiftUI

enum ColorTheme {
    case smartScan
    case cleanup
    case speed
    case applications
    case storage

    var primary: Color {
        switch self {
        case .smartScan: return Color(red: 0.31, green: 0.55, blue: 0.95)
        case .cleanup: return Color(red: 0.58, green: 0.42, blue: 0.92)
        case .speed: return Color(red: 0.36, green: 0.78, blue: 0.55)
        case .applications: return Color(red: 0.23, green: 0.51, blue: 0.96)
        case .storage: return Color(red: 0.46, green: 0.42, blue: 0.92)
        }
    }

    var secondary: Color {
        switch self {
        case .smartScan: return Color(red: 0.52, green: 0.76, blue: 0.98)
        case .cleanup: return Color(red: 0.74, green: 0.58, blue: 0.96)
        case .speed: return Color(red: 0.55, green: 0.88, blue: 0.70)
        case .applications: return Color(red: 0.46, green: 0.66, blue: 0.99)
        case .storage: return Color(red: 0.62, green: 0.58, blue: 0.98)
        }
    }

    var gradient: LinearGradient {
        LinearGradient(
            colors: [primary, secondary],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [
                primary.opacity(0.08),
                secondary.opacity(0.03)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
