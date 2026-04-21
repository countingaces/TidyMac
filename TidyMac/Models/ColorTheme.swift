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
        case .cleanup: return Color(red: 0.95, green: 0.55, blue: 0.33)
        case .speed: return Color(red: 0.36, green: 0.78, blue: 0.55)
        case .applications: return Color(red: 0.78, green: 0.36, blue: 0.72)
        case .storage: return Color(red: 0.46, green: 0.42, blue: 0.92)
        }
    }

    var secondary: Color {
        switch self {
        case .smartScan: return Color(red: 0.52, green: 0.76, blue: 0.98)
        case .cleanup: return Color(red: 0.98, green: 0.74, blue: 0.45)
        case .speed: return Color(red: 0.55, green: 0.88, blue: 0.70)
        case .applications: return Color(red: 0.92, green: 0.55, blue: 0.86)
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
