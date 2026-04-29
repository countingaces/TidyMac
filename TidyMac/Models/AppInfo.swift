import Foundation
import AppKit
import SwiftUI

struct AppInfo: Identifiable, @unchecked Sendable {
    let id: String              // Bundle identifier
    let name: String
    let version: String
    let bundlePath: URL
    let bundleSize: Int64
    let category: AppCategory
    let icon: NSImage
    let lastUsedDate: Date?
    let isSandboxed: Bool
    var remnants: [AppRemnant] = []

    var totalSize: Int64 {
        bundleSize + remnants.reduce(Int64(0)) { $0 + $1.size }
    }
}

extension AppInfo: Hashable {
    static func == (lhs: AppInfo, rhs: AppInfo) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

enum AppCategory: String, CaseIterable, Identifiable {
    case appleBuiltIn
    case appStore
    case thirdParty
    case utility
    case homebrew

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleBuiltIn: return "Apple"
        case .appStore:     return "App Store"
        case .thirdParty:   return "Third Party"
        case .utility:      return "Utility"
        case .homebrew:     return "Homebrew"
        }
    }

    var icon: String {
        switch self {
        case .appleBuiltIn: return "applelogo"
        case .appStore:     return "bag.fill"
        case .thirdParty:   return "shippingbox.fill"
        case .utility:      return "wrench.and.screwdriver.fill"
        case .homebrew:     return "mug.fill"
        }
    }

    var color: Color {
        switch self {
        case .appleBuiltIn: return Color.gray
        case .appStore:     return Color(red: 0.30, green: 0.55, blue: 0.95)
        case .thirdParty:   return Color(red: 0.62, green: 0.45, blue: 0.85)
        case .utility:      return Color(red: 0.50, green: 0.55, blue: 0.65)
        case .homebrew:     return Color(red: 0.95, green: 0.55, blue: 0.20)
        }
    }
}
