import Foundation

enum NavigationItem: String, CaseIterable, Identifiable, Hashable {
    case smartScan
    case systemJunk
    case largeOldFiles
    case optimization
    case maintenance
    case uninstaller
    case spaceLens

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smartScan: return "Smart Scan"
        case .systemJunk: return "System Junk"
        case .largeOldFiles: return "Large & Old Files"
        case .optimization: return "Optimization"
        case .maintenance: return "Maintenance"
        case .uninstaller: return "Uninstaller"
        case .spaceLens: return "Space Lens"
        }
    }

    var symbolName: String {
        switch self {
        case .smartScan: return "house.fill"
        case .systemJunk: return "trash.circle.fill"
        case .largeOldFiles: return "doc.text.magnifyingglass"
        case .optimization: return "gauge.with.dots.needle.67percent"
        case .maintenance: return "wrench.and.screwdriver.fill"
        case .uninstaller: return "xmark.app.fill"
        case .spaceLens: return "circle.grid.2x2.fill"
        }
    }

    var shortDescription: String {
        switch self {
        case .smartScan:
            return "Scan your Mac for opportunities to clean up and optimize in one sweep."
        case .systemJunk:
            return "Find caches, logs, and leftover files that are safe to remove."
        case .largeOldFiles:
            return "Surface the biggest, oldest files taking up space on your drive."
        case .optimization:
            return "Boost system responsiveness by freeing up memory and resources."
        case .maintenance:
            return "Run routine maintenance scripts to keep macOS healthy."
        case .uninstaller:
            return "Fully remove apps along with their leftover support files."
        case .spaceLens:
            return "Visualize how storage is distributed across folders and files."
        }
    }

    var theme: ColorTheme {
        switch self {
        case .smartScan: return .smartScan
        case .systemJunk: return .cleanup
        case .largeOldFiles: return .largeFiles
        case .optimization: return .optimization
        case .maintenance: return .maintenance
        case .uninstaller: return .applications
        case .spaceLens: return .storage
        }
    }
}

enum NavigationSection: String, CaseIterable, Identifiable {
    case cleanup
    case speed
    case applications
    case storage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cleanup: return "Cleanup"
        case .speed: return "Speed"
        case .applications: return "Applications"
        case .storage: return "Storage"
        }
    }

    var items: [NavigationItem] {
        switch self {
        case .cleanup: return [.systemJunk, .largeOldFiles]
        case .speed: return [.optimization, .maintenance]
        case .applications: return [.uninstaller]
        case .storage: return [.spaceLens]
        }
    }
}
