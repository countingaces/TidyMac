import Foundation

/// Step 1 placeholder — returns a neutral score until Step 2 replaces it
/// with the real weighted multi-component scoring rules. Lives at this
/// signature so the orchestrator can already wire results through.
enum HealthScoreCalculator {
    static func calculate(
        systemJunk: SystemJunkSummary?,
        optimization: OptimizationSummary?,
        maintenance: MaintenanceSummary?,
        orphans: OrphanSummary?
    ) -> HealthScore {
        return HealthScore(
            overall: 75,
            breakdown: [],
            grade: .good,
            headline: "Scan complete",
            recommendation: nil
        )
    }
}
