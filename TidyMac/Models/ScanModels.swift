import Foundation
import SwiftUI

// MARK: - Scan State

enum ScanState: Equatable {
    case idle
    case scanning(progress: ScanProgress)
    case complete
    case error(String)
}

struct ScanProgress: Equatable {
    var currentActivity: String
    var itemsFound: Int
    var sizeFound: Int64

    static let empty = ScanProgress(
        currentActivity: "",
        itemsFound: 0,
        sizeFound: 0
    )
}

// MARK: - Module Info

struct ModuleInfo {
    let id: String
    let title: String
    let description: String
    let icon: String
    let colorTheme: ColorTheme
    let features: [Feature]

    struct Feature: Identifiable {
        let id = UUID()
        let icon: String
        let title: String
        let subtitle: String
    }
}

// MARK: - Sort + Selection

enum SortMode: String, CaseIterable, Identifiable {
    case size, name

    var id: String { rawValue }

    var label: String {
        switch self {
        case .size: return "Size"
        case .name: return "Name"
        }
    }
}

enum SelectionState: Equatable {
    case none, partial, all
}

// MARK: - Safety Level

enum SafetyLevel: Equatable {
    case safe
    case cautious
    case risky

    var description: String {
        switch self {
        case .safe:     return "Safe to remove"
        case .cautious: return "Review before removing"
        case .risky:    return "May affect installed apps"
        }
    }

    var shortLabel: String {
        switch self {
        case .safe:     return "Safe"
        case .cautious: return "Review"
        case .risky:    return "Caution"
        }
    }

    var color: Color {
        switch self {
        case .safe:     return Color(red: 0.30, green: 0.78, blue: 0.50)
        case .cautious: return Color(red: 0.96, green: 0.65, blue: 0.20)
        case .risky:    return Color(red: 0.94, green: 0.40, blue: 0.40)
        }
    }
}

// MARK: - Scan Result

protocol ScanResult: Identifiable, Hashable {
    var id: UUID { get }
    var name: String { get }
    var path: URL { get }
    var size: Int64 { get }
    var safetyLevel: SafetyLevel { get }
}

// MARK: - Scan Category

struct ScanCategory<T: ScanResult>: Identifiable {
    let id: String
    let title: String
    let description: String
    let icon: String
    var items: [T]
    var isSelected: Bool

    var totalSize: Int64 {
        items.reduce(Int64(0)) { $0 + $1.size }
    }

    var humanReadableSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    var itemCount: Int { items.count }
}
