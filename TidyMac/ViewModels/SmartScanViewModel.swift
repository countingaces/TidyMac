import Foundation
import SwiftUI

@MainActor
final class SmartScanViewModel: ObservableObject {
    enum CleanState {
        case idle
        case cleaning(progress: CleaningService.Progress)
        case finished(CleaningService.CleaningResult)
    }

    @Published var cleanState: CleanState = .idle
    let orchestrator: SmartScanOrchestrator

    private let cleaningService = CleaningService()
    private var cleaningTask: Task<Void, Never>?

    init() {
        self.orchestrator = SmartScanOrchestrator()
        orchestrator.loadPersisted()
    }

    // MARK: - Convenience for the view

    var hasResults: Bool { orchestrator.results != nil }
    var results: SmartScanResults? { orchestrator.results }

    var isScanning: Bool {
        if case .scanning = orchestrator.overallState { return true }
        if case .completing = orchestrator.overallState { return true }
        return false
    }

    var isCleaning: Bool {
        if case .cleaning = cleanState { return true }
        return false
    }

    // MARK: - Actions

    func startScan(maintenanceLastRunDates: [String: Date]) {
        guard !isScanning else { return }
        orchestrator.startScan(maintenanceLastRunDates: maintenanceLastRunDates)
    }

    func stopScan() {
        orchestrator.cancelScan()
    }

    /// Cleans every safe-rated System Junk item from the most recent scan.
    /// Mirrors the System Junk module's "select all safe + Clean" flow.
    /// After cleaning, re-runs the orchestrator scan so the score and
    /// summaries reflect the new state.
    func cleanSafeJunk(maintenanceLastRunDates: [String: Date]) {
        guard !isCleaning else { return }
        let safeItems = orchestrator.lastJunkCategories
            .flatMap { $0.items }
            .filter { $0.safetyLevel == .safe }
        guard !safeItems.isEmpty else { return }

        cleaningTask = Task {
            cleanState = .cleaning(progress: CleaningService.Progress(
                currentItemName: safeItems.first?.name ?? "",
                itemsCompleted: 0,
                totalItems: safeItems.count,
                sizeFreedSoFar: 0
            ))
            let result = await cleaningService.clean(items: safeItems) { [weak self] progress in
                Task { @MainActor in
                    self?.cleanState = .cleaning(progress: progress)
                }
            }
            cleanState = .finished(result)
            // Refresh the score after a successful clean — the Smart Scan
            // results should now reflect the lower system junk total.
            orchestrator.startScan(maintenanceLastRunDates: maintenanceLastRunDates)
        }
    }

    func dismissCleaningResult() {
        cleanState = .idle
    }

    func cancelCleaning() {
        cleaningTask?.cancel()
    }

    // MARK: - Total cleanable size

    var safeCleanableSize: Int64 {
        orchestrator.lastJunkCategories
            .flatMap { $0.items }
            .filter { $0.safetyLevel == .safe }
            .reduce(Int64(0)) { $0 + $1.size }
    }

    var safeCleanableCount: Int {
        orchestrator.lastJunkCategories
            .flatMap { $0.items }
            .filter { $0.safetyLevel == .safe }
            .count
    }
}
