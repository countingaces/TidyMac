import Foundation
import AppKit

/// Coordinates a Smart Scan run across every active TidyMac module.
/// Each module is its own bulkhead — a failure in one (permission denied,
/// timeout, parser bug) is caught, marked as `.failed`, and the
/// orchestrator continues to the next. The user always gets at least
/// partial results rather than a blank screen with one error message.
@MainActor
final class SmartScanOrchestrator: ObservableObject {

    @Published var overallState: SmartScanState = .idle
    @Published var moduleStates: [String: ModuleProgress] = [:]
    @Published var results: SmartScanResults?

    /// In-memory cache of the most recent System Junk results. The
    /// persisted SmartScanResults only carries a summary, but the Smart
    /// Scan UI's "Clean" button — and the System Junk module when the
    /// user hits Review Details — needs the actual JunkItem instances.
    /// Cleared on app launch; user re-runs Smart Scan to refresh.
    private(set) var lastJunkCategories: [ScanCategory<JunkItem>] = []
    /// Same idea for orphan detection: in-memory cache of the OrphanDetector
    /// output so the Uninstaller can show pre-scanned orphans on Review
    /// Details rather than running orphan detection a second time.
    private(set) var lastOrphans: [OrphanDetector.Orphan] = []

    enum SmartScanState: Equatable {
        case idle
        case scanning(currentModule: String, overallProgress: Double)
        case completing
        case complete
        case error(String)
    }

    struct ModuleProgress: Equatable {
        let moduleId: String
        let moduleName: String
        let icon: String
        var state: ModuleState

        enum ModuleState: Equatable {
            case pending
            case running(detail: String)
            case complete(summary: String)
            case failed(error: String)
            case skipped(reason: String)
        }
    }

    // MARK: - Module catalog

    private struct Module: Sendable {
        let id: String
        let name: String
        let icon: String
        /// Fraction of total scan time this module is expected to consume.
        /// Sum across all modules = 1.0. Used to drive an honest progress
        /// bar — without weighting, the fast modules (Optimization,
        /// Maintenance) would jump the bar from 0 to 75% in a second
        /// then stall on System Junk.
        let weight: Double
    }

    private let modules: [Module] = [
        Module(id: "systemJunk",   name: "System Junk",       icon: "trash.circle.fill",                    weight: 0.50),
        Module(id: "orphans",      name: "Orphaned App Data", icon: "questionmark.folder.fill",             weight: 0.25),
        Module(id: "optimization", name: "Startup Health",    icon: "gauge.with.dots.needle.67percent",     weight: 0.15),
        Module(id: "maintenance", name: "Maintenance",        icon: "wrench.and.screwdriver.fill",          weight: 0.10)
    ]

    private var currentTask: Task<Void, Never>?

    // MARK: - Public API

    func startScan(maintenanceLastRunDates: [String: Date]) {
        guard currentTask == nil else { return }
        let started = Date()
        resetModuleStates()
        overallState = .scanning(currentModule: modules.first?.id ?? "", overallProgress: 0)

        currentTask = Task { [weak self] in
            await self?.runScan(maintenanceLastRunDates: maintenanceLastRunDates, started: started)
            await MainActor.run { self?.currentTask = nil }
        }
    }

    func cancelScan() {
        currentTask?.cancel()
    }

    /// Loads the most recent scan from disk if available. Lets the Smart
    /// Scan landing show last-scan summary across app launches.
    func loadPersisted() {
        results = SmartScanPersistence.load()
    }

    // MARK: - Run

    private func resetModuleStates() {
        var fresh: [String: ModuleProgress] = [:]
        for module in modules {
            fresh[module.id] = ModuleProgress(
                moduleId: module.id,
                moduleName: module.name,
                icon: module.icon,
                state: .pending
            )
        }
        moduleStates = fresh
    }

    private func runScan(maintenanceLastRunDates: [String: Date], started: Date) async {
        var systemJunk: SystemJunkSummary?
        var optimization: OptimizationSummary?
        var maintenance: MaintenanceSummary?
        var orphans: OrphanSummary?

        var cumulativeWeight = 0.0

        for module in modules {
            if Task.isCancelled { break }

            // Mark as running and update overall progress.
            updateModuleState(module.id, .running(detail: "Starting…"))
            overallState = .scanning(currentModule: module.id, overallProgress: cumulativeWeight)

            do {
                switch module.id {
                case "systemJunk":
                    systemJunk = try await scanSystemJunk(module: module, baseProgress: cumulativeWeight)
                case "orphans":
                    orphans = try await scanOrphans(module: module, baseProgress: cumulativeWeight)
                case "optimization":
                    optimization = try await scanOptimization(module: module, baseProgress: cumulativeWeight)
                case "maintenance":
                    maintenance = try await scanMaintenance(module: module, lastRunDates: maintenanceLastRunDates)
                default:
                    break
                }
            } catch is CancellationError {
                updateModuleState(module.id, .skipped(reason: "Cancelled"))
            } catch {
                updateModuleState(module.id, .failed(error: error.localizedDescription))
            }

            cumulativeWeight += module.weight
            overallState = .scanning(currentModule: module.id, overallProgress: cumulativeWeight)
        }

        // Mark any still-pending modules as skipped (cancellation case).
        for module in modules {
            if case .pending = moduleStates[module.id]?.state {
                updateModuleState(module.id, .skipped(reason: "Cancelled"))
            } else if case .running = moduleStates[module.id]?.state {
                updateModuleState(module.id, .skipped(reason: "Cancelled"))
            }
        }

        overallState = .completing

        let healthScore = HealthScoreCalculator.calculate(
            systemJunk: systemJunk,
            optimization: optimization,
            maintenance: maintenance,
            orphans: orphans
        )

        let aggregated = SmartScanResults(
            systemJunk: systemJunk,
            optimization: optimization,
            maintenance: maintenance,
            orphanedFiles: orphans,
            healthScore: healthScore,
            scanDuration: Date().timeIntervalSince(started),
            timestamp: Date()
        )

        results = aggregated
        SmartScanPersistence.save(aggregated)
        overallState = .complete
    }

    private func updateModuleState(_ id: String, _ state: ModuleProgress.ModuleState) {
        guard var existing = moduleStates[id] else { return }
        existing.state = state
        moduleStates[id] = existing
    }

    // MARK: - Per-module scans

    private func scanSystemJunk(module: Module, baseProgress: Double) async throws -> SystemJunkSummary {
        let scanner = SystemJunkScanner()
        let categories = try await scanner.scan { [weak self] progress in
            Task { @MainActor in
                self?.updateModuleState(module.id, .running(detail: progress.currentActivity))
                self?.overallState = .scanning(
                    currentModule: module.id,
                    overallProgress: baseProgress + module.weight * 0.5
                )
            }
        }
        lastJunkCategories = categories
        let totalSize = categories.reduce(Int64(0)) { $0 + $1.totalSize }
        let totalItems = categories.reduce(0) { $0 + $1.itemCount }
        let safeSize = categories.flatMap { $0.items }
            .filter { $0.safetyLevel == .safe }
            .reduce(Int64(0)) { $0 + $1.size }

        let staleSize = categories.flatMap { $0.items }
            .filter { Self.isStale($0) }
            .reduce(Int64(0)) { $0 + $1.size }

        let summary = SystemJunkSummary(
            totalSize: totalSize,
            totalItems: totalItems,
            safeSize: safeSize,
            staleSize: staleSize,
            categoryCount: categories.count
        )
        updateModuleState(module.id, .complete(summary: summary.headline))
        return summary
    }

    /// "Stale" = log/cache item older than 30 days. Health score weighs
    /// stale items more heavily than active caches (an active cache is
    /// healthy; a stale one is rot).
    private static func isStale(_ item: JunkItem) -> Bool {
        guard let mtime = item.lastModified else { return false }
        return Date().timeIntervalSince(mtime) > 30 * 24 * 60 * 60
    }

    private func scanOrphans(module: Module, baseProgress: Double) async throws -> OrphanSummary {
        updateModuleState(module.id, .running(detail: "Looking for orphaned app files…"))
        overallState = .scanning(
            currentModule: module.id,
            overallProgress: baseProgress + module.weight * 0.5
        )

        let installed = await AppDiscoveryService().discoverApps()
        try Task.checkCancellation()
        let installedIds = Set(installed.map { $0.id })
        let orphans = await OrphanDetector().detect(installedBundleIds: installedIds)
        lastOrphans = orphans
        let totalSize = orphans.reduce(Int64(0)) { $0 + $1.totalSize }

        let summary = OrphanSummary(
            count: orphans.count,
            totalSize: totalSize
        )
        updateModuleState(module.id, .complete(summary: summary.headline))
        return summary
    }

    private func scanOptimization(module: Module, baseProgress: Double) async throws -> OptimizationSummary {
        updateModuleState(module.id, .running(detail: "Inspecting startup items…"))
        overallState = .scanning(
            currentModule: module.id,
            overallProgress: baseProgress + module.weight * 0.5
        )

        let scanner = OptimizationScanner()
        let items = await scanner.scan()
        try Task.checkCancellation()

        let agentItems = items.filter {
            StartupItem.category(for: $0.source, type: $0.type) == .launchAgents
        }
        let loginItems = items.filter {
            StartupItem.category(for: $0.source, type: $0.type) == .loginItems
        }
        let hungApps = items.filter { $0.type == .hungApp }

        let broken = agentItems.filter { $0.isExecutableMissing }.count
        let orphaned = agentItems.filter { $0.isParentAppMissing }.count

        let summary = OptimizationSummary(
            totalAgents: agentItems.count,
            brokenAgentCount: broken,
            orphanedAgentCount: orphaned,
            loginItemCount: loginItems.count,
            hungAppCount: hungApps.count
        )
        updateModuleState(module.id, .complete(summary: summary.headline))
        return summary
    }

    private func scanMaintenance(module: Module, lastRunDates: [String: Date]) async throws -> MaintenanceSummary {
        updateModuleState(module.id, .running(detail: "Checking last-run dates…"))

        // Maintenance is just a metadata check — no IO. List the catalog,
        // compare each task's last-run date against staleness thresholds.
        let tasks = MaintenanceCatalog.availableTasks()
        let now = Date()
        let staleThreshold: TimeInterval = 30 * 24 * 60 * 60   // 30 days
        let veryStaleThreshold: TimeInterval = 90 * 24 * 60 * 60 // 90 days

        var neverRun = 0
        var stale = 0
        var veryStale = 0
        var freshest: Date?

        for task in tasks {
            let last = lastRunDates[task.id]
            if let date = last {
                if freshest == nil || date > freshest! { freshest = date }
                let age = now.timeIntervalSince(date)
                if age > veryStaleThreshold { veryStale += 1 }
                else if age > staleThreshold { stale += 1 }
            } else {
                neverRun += 1
            }
        }

        let summary = MaintenanceSummary(
            totalTasks: tasks.count,
            neverRunCount: neverRun,
            staleCount: stale,
            veryStaleCount: veryStale,
            freshestRun: freshest
        )
        updateModuleState(module.id, .complete(summary: summary.headline))
        return summary
    }
}

// MARK: - Result models

struct SmartScanResults: Codable, Equatable {
    let systemJunk: SystemJunkSummary?
    let optimization: OptimizationSummary?
    let maintenance: MaintenanceSummary?
    let orphanedFiles: OrphanSummary?
    let healthScore: HealthScore
    let scanDuration: TimeInterval
    let timestamp: Date
}

struct SystemJunkSummary: Codable, Equatable {
    let totalSize: Int64
    let totalItems: Int
    let safeSize: Int64
    let staleSize: Int64
    let categoryCount: Int

    var headline: String {
        if totalSize == 0 { return "No junk found" }
        return "\(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)) of cleanable junk"
    }
}

struct OptimizationSummary: Codable, Equatable {
    let totalAgents: Int
    let brokenAgentCount: Int
    let orphanedAgentCount: Int
    let loginItemCount: Int
    let hungAppCount: Int

    var issueCount: Int {
        brokenAgentCount + orphanedAgentCount + hungAppCount
    }

    var headline: String {
        if issueCount == 0 { return "No issues found" }
        var parts: [String] = []
        if brokenAgentCount > 0 { parts.append("\(brokenAgentCount) broken") }
        if orphanedAgentCount > 0 { parts.append("\(orphanedAgentCount) orphaned") }
        if hungAppCount > 0 { parts.append("\(hungAppCount) hung") }
        return parts.joined(separator: ", ")
    }
}

struct MaintenanceSummary: Codable, Equatable {
    let totalTasks: Int
    let neverRunCount: Int
    let staleCount: Int
    let veryStaleCount: Int
    let freshestRun: Date?

    var overdueCount: Int {
        neverRunCount + staleCount + veryStaleCount
    }

    var headline: String {
        if overdueCount == 0 { return "All up to date" }
        return "\(overdueCount) task\(overdueCount == 1 ? "" : "s") recommended"
    }
}

struct OrphanSummary: Codable, Equatable {
    let count: Int
    let totalSize: Int64

    var headline: String {
        if count == 0 { return "No orphaned files" }
        return "\(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)) across \(count) removed app\(count == 1 ? "" : "s")"
    }
}

// MARK: - Persistence

enum SmartScanPersistence {
    static var fileURL: URL {
        let support = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/TidyMac", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("smart-scan.json")
    }

    static func save(_ results: SmartScanResults) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(results) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func load() -> SmartScanResults? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SmartScanResults.self, from: data)
    }
}
