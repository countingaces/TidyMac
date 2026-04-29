import Foundation

/// Composes a HealthScore from per-module summaries. Each component is
/// scored 0-100 by its own rules, then combined with fixed weights. The
/// numbers in here are product decisions, not technical ones — they
/// encode TidyMac's stance that the score should drive useful behavior,
/// not anxiety.
///
/// **Anti-manipulation rules** (each one a deliberate design choice):
/// 1. Active app caches DO NOT reduce the score. Caches are supposed to
///    exist; counting them against the user is what cleaning apps do to
///    sell subscriptions. Only stale items (logs > 30 days, caches from
///    uninstalled apps) drop the System Junk score.
/// 2. The score never drops below 30 unless there's a genuine problem
///    (broken Launch Agents, disk under 5% free). A "your Mac is in
///    crisis" red number for someone whose only sin is having lots of
///    Spotify cache would be dishonest.
/// 3. The maximum is 98, not 100. A 100% score feels manufactured;
///    leaving headroom for "real perfection" keeps the metric honest.
/// 4. The score is reproducible — same inputs in, same number out. No
///    randomness, no time-of-day variance.
enum HealthScoreCalculator {

    private static let weights: [String: Double] = [
        "disk":         0.30,
        "systemJunk":   0.20,
        "startup":      0.25,
        "maintenance":  0.15,
        "orphans":      0.10
    ]

    /// Hard ceiling: a "perfect" Mac scores 98, not 100. Perfection is
    /// suspicious — the missing 2 points are an honest reminder that no
    /// system is ever truly issue-free.
    private static let maxOverall = 98

    /// Floor when no genuine issues are present. Without this, a Mac
    /// with merely a lot of cleanable cache would score below 30 and
    /// alarm the user despite being fine.
    private static let benignFloor = 30

    static func calculate(
        systemJunk: SystemJunkSummary?,
        optimization: OptimizationSummary?,
        maintenance: MaintenanceSummary?,
        orphans: OrphanSummary?
    ) -> HealthScore {
        let disk = scoreDisk()
        let junk = scoreSystemJunk(systemJunk)
        let startup = scoreStartup(optimization)
        let maint = scoreMaintenance(maintenance)
        let orphan = scoreOrphans(orphans)

        let components = [disk, junk, startup, maint, orphan]

        let weightedSum = components.reduce(0.0) { sum, c in
            sum + Double(c.score) * c.weight
        }
        var raw = Int(weightedSum.rounded())

        // Apply the perfection ceiling.
        raw = min(raw, maxOverall)

        // Apply the benign floor — but only when no genuine issue exists.
        // Genuine issues = broken/orphaned launch agents, hung apps,
        // disk under 5% free. Anything else is "your Mac is fine, just
        // accumulated some entropy."
        if !hasGenuineIssue(disk: disk, optimization: optimization) {
            raw = max(raw, benignFloor)
        }

        let grade = grade(for: raw)
        let lowest = components.min(by: { $0.score < $1.score })
        let headline = headline(score: raw, grade: grade, lowest: lowest)
        let recommendation = recommendation(
            score: raw,
            grade: grade,
            disk: disk,
            junk: junk,
            startup: startup,
            maint: maint,
            orphan: orphan,
            systemJunk: systemJunk,
            optimization: optimization,
            maintenance: maintenance,
            orphans: orphans
        )

        return HealthScore(
            overall: raw,
            breakdown: components,
            grade: grade,
            headline: headline,
            recommendation: recommendation
        )
    }

    // MARK: - Components

    /// Disk Space (weight 0.30).
    /// 100 = >20% free, 80 = 10-20%, 50 = 5-10%, 20 = <5%.
    /// Measures actual health, not whether caches exist.
    private static func scoreDisk() -> HealthScore.ScoreComponent {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        var freePct: Double = 1.0
        var freeBytes: Int64 = 0
        var totalBytes: Int64 = 0
        if let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityKey, .volumeTotalCapacityKey
        ]),
           let free = values.volumeAvailableCapacity,
           let total = values.volumeTotalCapacity,
           total > 0 {
            freeBytes = Int64(free)
            totalBytes = Int64(total)
            freePct = Double(free) / Double(total)
        }

        let score: Int
        if freePct > 0.20 { score = 100 }
        else if freePct > 0.10 { score = 80 }
        else if freePct > 0.05 { score = 50 }
        else { score = 20 }

        let detail: String = {
            let pctStr = String(format: "%.1f%%", freePct * 100)
            let bytesStr = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
            if totalBytes == 0 { return "Free space unknown" }
            return "\(bytesStr) free (\(pctStr) of disk)"
        }()

        return HealthScore.ScoreComponent(
            category: "Disk Space",
            score: score,
            weight: weights["disk"]!,
            detail: detail,
            actionable: freePct < 0.20
        )
    }

    /// System Junk (weight 0.20).
    /// Score based on STALE bytes only — active caches are healthy.
    /// 100 = no stale, 80 = <1 GB stale, 60 = 1-5 GB, 40 = 5-20 GB, 20 = >20 GB.
    private static func scoreSystemJunk(_ summary: SystemJunkSummary?) -> HealthScore.ScoreComponent {
        guard let summary else {
            return HealthScore.ScoreComponent(
                category: "System Junk",
                score: 100,
                weight: weights["systemJunk"]!,
                detail: "Not scanned",
                actionable: false
            )
        }
        let stale = summary.staleSize
        let oneGB: Int64 = 1_073_741_824
        let score: Int
        if stale == 0 { score = 100 }
        else if stale < oneGB { score = 80 }
        else if stale < 5 * oneGB { score = 60 }
        else if stale < 20 * oneGB { score = 40 }
        else { score = 20 }

        let detail: String = {
            if summary.totalSize == 0 { return "No junk found" }
            let totalStr = ByteCountFormatter.string(fromByteCount: summary.totalSize, countStyle: .file)
            if stale == 0 { return "\(totalStr) of cleanable junk (none stale)" }
            let staleStr = ByteCountFormatter.string(fromByteCount: stale, countStyle: .file)
            return "\(totalStr) of cleanable junk (\(staleStr) stale)"
        }()

        return HealthScore.ScoreComponent(
            category: "System Junk",
            score: score,
            weight: weights["systemJunk"]!,
            detail: detail,
            actionable: summary.totalSize > 0
        )
    }

    /// Startup Health (weight 0.25).
    /// 100 = no broken/orphaned, <5 login items
    /// 80 = clean but 5-10 login items
    /// 50 = broken/orphaned/hung found
    /// 30 = 3+ broken (anomalies pile up)
    private static func scoreStartup(_ summary: OptimizationSummary?) -> HealthScore.ScoreComponent {
        guard let summary else {
            return HealthScore.ScoreComponent(
                category: "Startup Health",
                score: 100,
                weight: weights["startup"]!,
                detail: "Not scanned",
                actionable: false
            )
        }
        let issueTotal = summary.brokenAgentCount + summary.orphanedAgentCount + summary.hungAppCount
        let score: Int
        if summary.brokenAgentCount >= 3 { score = 30 }
        else if issueTotal > 0 { score = 50 }
        else if summary.loginItemCount > 10 { score = 60 }
        else if summary.loginItemCount >= 5 { score = 80 }
        else { score = 100 }

        let detail: String = {
            if issueTotal == 0 && summary.totalAgents == 0 {
                return "No third-party launch agents detected"
            }
            if issueTotal == 0 {
                return "\(summary.totalAgents) launch agent\(summary.totalAgents == 1 ? "" : "s"), all healthy"
            }
            return summary.headline
        }()

        return HealthScore.ScoreComponent(
            category: "Startup Health",
            score: score,
            weight: weights["startup"]!,
            detail: detail,
            actionable: issueTotal > 0
        )
    }

    /// Maintenance (weight 0.15).
    /// 100 = all run in last 30 days, 80 = mostly within 60 days,
    /// 50 = some never run or > 90 days. Gentle nudge, not alarm.
    private static func scoreMaintenance(_ summary: MaintenanceSummary?) -> HealthScore.ScoreComponent {
        guard let summary else {
            return HealthScore.ScoreComponent(
                category: "Maintenance",
                score: 80,
                weight: weights["maintenance"]!,
                detail: "Not scanned",
                actionable: false
            )
        }
        let total = summary.totalTasks
        let veryStale = summary.veryStaleCount + summary.neverRunCount
        let stale = summary.staleCount

        let score: Int
        if total == 0 { score = 100 }
        else if veryStale == 0 && stale == 0 { score = 100 }
        else if veryStale == 0 { score = 80 }
        else if veryStale < total { score = 50 }
        else { score = 30 }

        let detail: String = {
            if total == 0 { return "No tasks available" }
            return summary.headline
        }()

        return HealthScore.ScoreComponent(
            category: "Maintenance",
            score: score,
            weight: weights["maintenance"]!,
            detail: detail,
            actionable: veryStale > 0 || stale > 0
        )
    }

    /// Orphaned Files (weight 0.10).
    /// 100 = none, 80 = <500 MB, 60 = 500 MB - 2 GB, 40 = >2 GB.
    private static func scoreOrphans(_ summary: OrphanSummary?) -> HealthScore.ScoreComponent {
        guard let summary else {
            return HealthScore.ScoreComponent(
                category: "Orphaned Files",
                score: 100,
                weight: weights["orphans"]!,
                detail: "Not scanned",
                actionable: false
            )
        }
        let halfGB: Int64 = 500 * 1_048_576
        let twoGB: Int64 = 2 * 1_073_741_824
        let score: Int
        if summary.count == 0 { score = 100 }
        else if summary.totalSize < halfGB { score = 80 }
        else if summary.totalSize < twoGB { score = 60 }
        else { score = 40 }

        return HealthScore.ScoreComponent(
            category: "Orphaned Files",
            score: score,
            weight: weights["orphans"]!,
            detail: summary.headline,
            actionable: summary.count > 0
        )
    }

    // MARK: - Issue gating

    private static func hasGenuineIssue(
        disk: HealthScore.ScoreComponent,
        optimization: OptimizationSummary?
    ) -> Bool {
        if disk.score <= 20 { return true } // <5% free is a real problem
        if let opt = optimization,
           opt.brokenAgentCount + opt.orphanedAgentCount + opt.hungAppCount > 0 {
            return true
        }
        return false
    }

    // MARK: - Grade + headline

    private static func grade(for score: Int) -> HealthScore.Grade {
        switch score {
        case 90...: return .excellent
        case 70..<90: return .good
        case 50..<70: return .fair
        default: return .needsAttention
        }
    }

    private static func headline(
        score: Int,
        grade: HealthScore.Grade,
        lowest: HealthScore.ScoreComponent?
    ) -> String {
        switch grade {
        case .excellent:
            return "Your Mac is in great shape"
        case .good:
            if let lowest, lowest.score < 90 {
                return "Your Mac is doing well — \(lowest.category.lowercased()) could be tightened up"
            }
            return "Your Mac is doing well"
        case .fair:
            return "Your Mac could use some attention"
        case .needsAttention:
            return "Your Mac needs maintenance"
        }
    }

    private static func recommendation(
        score: Int,
        grade: HealthScore.Grade,
        disk: HealthScore.ScoreComponent,
        junk: HealthScore.ScoreComponent,
        startup: HealthScore.ScoreComponent,
        maint: HealthScore.ScoreComponent,
        orphan: HealthScore.ScoreComponent,
        systemJunk: SystemJunkSummary?,
        optimization: OptimizationSummary?,
        maintenance: MaintenanceSummary?,
        orphans: OrphanSummary?
    ) -> String? {
        // No nudges at the top tier — leave the user alone.
        guard grade != .excellent else { return nil }

        // Pick the single most-actionable component to recommend on.
        let candidates: [(HealthScore.ScoreComponent, String)] = [
            (startup, optimization.flatMap(startupRec) ?? ""),
            (disk, diskRec(disk)),
            (junk, junkRec(systemJunk)),
            (orphan, orphanRec(orphans)),
            (maint, maintenanceRec(maintenance))
        ]

        let actionable = candidates
            .filter { $0.0.actionable && !$0.1.isEmpty }
            .sorted { $0.0.score < $1.0.score }

        return actionable.first?.1
    }

    private static func startupRec(_ s: OptimizationSummary) -> String? {
        let issues = s.brokenAgentCount + s.orphanedAgentCount + s.hungAppCount
        guard issues > 0 else { return nil }
        return "Visit Optimization to clean up \(issues) startup issue\(issues == 1 ? "" : "s")."
    }

    private static func diskRec(_ c: HealthScore.ScoreComponent) -> String {
        c.score < 50 ? "Free up disk space — your boot volume is running low." : ""
    }

    private static func junkRec(_ s: SystemJunkSummary?) -> String {
        guard let s, s.totalSize > 1_073_741_824 else { return "" }
        let str = ByteCountFormatter.string(fromByteCount: s.totalSize, countStyle: .file)
        return "Run System Junk cleanup to reclaim \(str)."
    }

    private static func orphanRec(_ s: OrphanSummary?) -> String {
        guard let s, s.count > 0 else { return "" }
        return "Remove \(s.count) orphaned app data folder\(s.count == 1 ? "" : "s") in Uninstaller."
    }

    private static func maintenanceRec(_ s: MaintenanceSummary?) -> String {
        guard let s, s.overdueCount > 0 else { return "" }
        return "Run \(s.overdueCount) recommended maintenance task\(s.overdueCount == 1 ? "" : "s")."
    }
}
