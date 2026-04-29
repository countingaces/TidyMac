import Foundation
import SwiftUI

// Step 2 stub — full implementation lands in Step 3 (Remnant Scanner).
// Defined here so AppInfo's `remnants` property compiles.
struct AppRemnant: Identifiable, Hashable {
    let id: UUID
    let path: URL
    let size: Int64
    let category: RemnantCategory
    let matchConfidence: MatchConfidence
    let description: String

    init(
        id: UUID = UUID(),
        path: URL,
        size: Int64,
        category: RemnantCategory,
        matchConfidence: MatchConfidence,
        description: String
    ) {
        self.id = id
        self.path = path
        self.size = size
        self.category = category
        self.matchConfidence = matchConfidence
        self.description = description
    }

    enum RemnantCategory: String, CaseIterable, Identifiable {
        case applicationSupport
        case container
        case cache
        case preferences
        case savedState
        case logs
        case launchAgent
        case loginItem
        case cookies
        case httpStorage
        case webkitData
        case crashReports
        case other

        var id: String { rawValue }
        var displayName: String { "" }
        var icon: String { "doc" }
        var safetyLevel: SafetyLevel { .safe }
    }

    enum MatchConfidence: Int, Comparable {
        case fuzzy = 0
        case nameMatch = 1
        case prefixMatch = 2
        case exact = 3

        static func < (lhs: MatchConfidence, rhs: MatchConfidence) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AppRemnant, rhs: AppRemnant) -> Bool {
        lhs.id == rhs.id
    }
}
