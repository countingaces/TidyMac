import Foundation
import SwiftUI

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
        description: String = ""
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

        var displayName: String {
            switch self {
            case .applicationSupport: return "Application Support"
            case .container:          return "Container"
            case .cache:              return "Cache"
            case .preferences:        return "Preferences"
            case .savedState:         return "Saved Application State"
            case .logs:               return "Logs"
            case .launchAgent:        return "Launch Agent"
            case .loginItem:          return "Login Item"
            case .cookies:            return "Cookies"
            case .httpStorage:        return "HTTP Storage"
            case .webkitData:         return "WebKit Data"
            case .crashReports:       return "Crash Reports"
            case .other:              return "Other"
            }
        }

        var icon: String {
            switch self {
            case .applicationSupport: return "folder.fill"
            case .container:          return "shippingbox.fill"
            case .cache:              return "internaldrive"
            case .preferences:        return "slider.horizontal.3"
            case .savedState:         return "clock.arrow.circlepath"
            case .logs:               return "doc.text"
            case .launchAgent:        return "gearshape.2.fill"
            case .loginItem:          return "person.crop.circle.fill"
            case .cookies:            return "circle.dashed"
            case .httpStorage:        return "network"
            case .webkitData:         return "globe"
            case .crashReports:       return "exclamationmark.triangle"
            case .other:              return "questionmark.folder"
            }
        }

        var safetyLevel: SafetyLevel {
            switch self {
            case .cache, .savedState, .logs, .cookies,
                 .httpStorage, .webkitData, .crashReports:
                return .safe
            case .applicationSupport, .container, .preferences,
                 .launchAgent, .loginItem, .other:
                return .cautious
            }
        }
    }

    enum MatchConfidence: Int, Comparable {
        case fuzzy = 0
        case nameMatch = 1
        case prefixMatch = 2
        case exact = 3

        static func < (lhs: MatchConfidence, rhs: MatchConfidence) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var label: String {
            switch self {
            case .exact:       return "Exact match"
            case .prefixMatch: return "Bundle prefix"
            case .nameMatch:   return "Probable match"
            case .fuzzy:       return "Uncertain match"
            }
        }

        var color: Color {
            switch self {
            case .exact, .prefixMatch: return SafetyLevel.safe.color
            case .nameMatch:           return SafetyLevel.cautious.color
            case .fuzzy:               return SafetyLevel.risky.color
            }
        }

        /// Pre-checked in the UI when the match is unambiguous.
        var isAutoSelected: Bool {
            self == .exact || self == .prefixMatch
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AppRemnant, rhs: AppRemnant) -> Bool {
        lhs.id == rhs.id
    }
}
