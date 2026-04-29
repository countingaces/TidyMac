import Foundation
import SwiftUI
import AppKit

@MainActor
final class SystemJunkViewModel: ObservableObject, ScanModule {
    typealias ResultType = JunkItem

    let moduleInfo = ModuleInfo(
        id: "systemJunk",
        title: "System Junk",
        description: "Find and remove system files that clutter your Mac",
        icon: "trash.circle.fill",
        colorTheme: .cleanup,
        features: [
            ModuleInfo.Feature(
                icon: "scope",
                title: "Deep clean",
                subtitle: "Removes caches, logs, and temporary files that accumulate over time"
            ),
            ModuleInfo.Feature(
                icon: "wand.and.rays",
                title: "Smart detection",
                subtitle: "Identifies junk from specific apps like Xcode, browsers, and mail"
            )
        ]
    )

    // MARK: - ScanModule conformance (stored)

    @Published var scanState: ScanState = .idle
    @Published var results: [ScanCategory<JunkItem>] = []
    @Published var selectedItemIds: Set<UUID> = []
    @Published var selectedCategoryId: String?
    @Published var sortMode: SortMode = .size

    // MARK: - Cleaning-flow state (not in protocol)

    @Published var cleaningPhase: CleaningPhase = .idle
    @Published var runningAppsToQuit: [NSRunningApplication] = []
    @Published var alertMessage: String?

    enum CleaningPhase {
        case idle
        case awaitingQuitDecision
        case inProgress(CleaningService.Progress)
        case finished(CleaningService.CleaningResult)
    }

    var isCleaning: Bool {
        if case .inProgress = cleaningPhase { return true }
        return false
    }

    // MARK: - Internal

    private var scanTask: Task<Void, Error>?
    private var cleanTask: Task<Void, Never>?
    private let scanner = SystemJunkScanner()
    private let cleaningService = CleaningService()

    // MARK: - ScanModule conformance (methods)

    func startScan() async {
        scanTask?.cancel()
        let task = Task<Void, Error> { try await self.performScan() }
        scanTask = task
        do {
            try await task.value
        } catch is CancellationError {
            scanState = .idle
        } catch {
            scanState = .error(error.localizedDescription)
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanState = .idle
    }

    func clean(items: [JunkItem]) async throws {
        guard !items.isEmpty else { return }
        let result = await cleaningService.clean(items: items, onProgress: { _ in })
        prune(items: items, against: result.log)
        if result.itemsCleaned == 0 && !result.failures.isEmpty {
            throw CleaningService.CleaningError.recycleFailed
        }
    }

    private func performScan() async throws {
        scanState = .scanning(progress: .empty)
        results = []
        selectedItemIds = []
        selectedCategoryId = nil

        let scanned = try await scanner.scan { progress in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scanState = .scanning(progress: ScanProgress(
                    currentActivity: progress.currentActivity,
                    itemsFound: progress.itemsFound,
                    sizeFound: progress.sizeFound
                ))
            }
        }
        try Task.checkCancellation()

        self.results = scanned
        self.selectAllSafe()
        self.selectedCategoryId = sortedCategories.first?.id
        self.scanState = .complete
    }

    // MARK: - Rich cleaning flow

    func requestClean() {
        let conflicting = CleaningService.conflictingRunningApps(for: selectedItems)
        runningAppsToQuit = conflicting
        if conflicting.isEmpty {
            beginCleaning()
        } else {
            cleaningPhase = .awaitingQuitDecision
        }
    }

    func quitApp(_ app: NSRunningApplication) {
        CleaningService.quit(app)
    }

    func quitAllAndContinue() {
        CleaningService.quitAll(runningAppsToQuit)
        cleanTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { [weak self] in
                self?.beginCleaning()
            }
        }
    }

    func ignoreAndContinue() {
        beginCleaning()
    }

    func cancelCleaningPreflight() {
        runningAppsToQuit = []
        cleaningPhase = .idle
    }

    func cancelCleaning() {
        cleanTask?.cancel()
        cleanTask = nil
    }

    func dismissCompletion() {
        cleaningPhase = .idle
        runningAppsToQuit = []
        scanState = .idle
        results = []
        selectedItemIds = []
        selectedCategoryId = nil
    }

    private func beginCleaning() {
        let items = selectedItems
        guard !items.isEmpty else {
            cleaningPhase = .idle
            runningAppsToQuit = []
            return
        }

        cleaningPhase = .inProgress(CleaningService.Progress(
            currentItemName: "",
            itemsCompleted: 0,
            totalItems: items.count,
            sizeFreedSoFar: 0
        ))

        cleanTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.cleaningService.clean(items: items) { progress in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if case .inProgress = self.cleaningPhase {
                        self.cleaningPhase = .inProgress(progress)
                    }
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.prune(items: items, against: result.log)
                self.runningAppsToQuit = []
                self.cleaningPhase = .finished(result)
            }
        }
    }

    private func prune(items: [JunkItem], against log: [CleaningService.CleaningLogEntry]) {
        let cleanedURLs = Set(log.filter { $0.success }.map { $0.path })
        let cleanedIds: Set<UUID> = Set(
            items.filter { cleanedURLs.contains($0.path) }.map { $0.id }
        )
        guard !cleanedIds.isEmpty else { return }

        for catIdx in results.indices {
            results[catIdx].items.removeAll { cleanedIds.contains($0.id) }
        }
        results.removeAll { $0.items.isEmpty }
        selectedItemIds.subtract(cleanedIds)

        if let id = selectedCategoryId, !results.contains(where: { $0.id == id }) {
            selectedCategoryId = sortedCategories.first?.id
        }
    }
}
