import Foundation
import SwiftUI

/// A composite system-health metric (0-100). Surfaced on the Smart Scan
/// landing as the headline number, plus a per-component breakdown so the
/// user can see *why* the score is what it is. Persisted as part of
/// SmartScanResults across app launches.
struct HealthScore: Codable, Equatable {
    let overall: Int
    let breakdown: [ScoreComponent]
    let grade: Grade
    let headline: String
    let recommendation: String?

    enum Grade: String, Codable {
        case excellent       // 90-100
        case good            // 70-89
        case fair            // 50-69
        case needsAttention  // 0-49

        var color: Color {
            switch self {
            case .excellent: return Color(red: 0.36, green: 0.78, blue: 0.55)
            case .good: return Color(red: 0.36, green: 0.78, blue: 0.55).opacity(0.85)
            case .fair: return Color.orange
            case .needsAttention: return Color.red
            }
        }

        var label: String {
            switch self {
            case .excellent: return "Excellent"
            case .good: return "Good"
            case .fair: return "Fair"
            case .needsAttention: return "Needs Attention"
            }
        }
    }

    struct ScoreComponent: Codable, Equatable, Identifiable {
        let category: String
        let score: Int
        let weight: Double
        let detail: String
        let actionable: Bool

        var id: String { category }
    }
}
