import Foundation
import SwiftUI
import AppKit

@MainActor
final class SystemJunkViewModel: ObservableObject, ScanModule {
    typealias ResultType = JunkItem

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

    let moduleInfo = ModuleInfo(
        id: "systemJunk",
        title: "System Junk",
        description: "Find and remove system files that clutter your Mac",
        icon: "trash.circle.fill",
        colorTheme: .cleanup
    )

    @Published var scanState: ScanState = .idle
    @Published var results: [ScanCategory<JunkItem>] = []
    @Published var selectedItemIds: Set<UUID> = []
    @Published var selectedCategoryId: String?
    @Published var sortMode: SortMode = .size
    @Published var alertMessage: String?

    @Published var cleaningPhase: CleaningPhase = .idle
    @Published var runningAppsToQuit: [NSRunningApplication] = []

    enum CleaningPhase {
        case idle
        case awaitingQuitDecision
        case inProgress(CleaningService.Progress)
        case finished(CleaningService.CleaningResult)
    }

    private var scanTask: Task<Void, Never>?
    private var cleanTask: Task<Void, Never>?
    private let scanner = SystemJunkScanner()
    private let cleaningService = CleaningService()

    // MARK: - Derived state

    var selectedSize: Int64 {
        results.flatMap { $0.items }
            .filter { selectedItemIds.contains($0.id) }
            .reduce(Int64(0)) { $0 + $1.size }
    }

    var totalCleanableSize: Int64 {
        results.reduce(Int64(0)) { $0 + $1.totalSize }
    }

    var selectedItems: [JunkItem] {
        results.flatMap { $0.items }.filter { selectedItemIds.contains($0.id) }
    }

    var selectedCategory: ScanCategory<JunkItem>? {
        guard let id = selectedCategoryId else { return nil }
        return results.first { $0.id == id }
    }

    var sortedCategories: [ScanCategory<JunkItem>] {
        switch sortMode {
        case .size: return results.sorted { $0.totalSize > $1.totalSize }
        case .name: return results.sorted { $0.title < $1.title }
        }
    }

    func sortedItems(in category: ScanCategory<JunkItem>) -> [JunkItem] {
        switch sortMode {
        case .size: return category.items.sorted { $0.size > $1.size }
        case .name: return category.items.sorted { $0.name < $1.name }
        }
    }

    func selectionState(for category: ScanCategory<JunkItem>) -> SelectionState {
        let total = category.items.count
        guard total > 0 else { return .none }
        let selected = category.items.filter { selectedItemIds.contains($0.id) }.count
        if selected == 0 { return .none }
        if selected == total { return .all }
        return .partial
    }

    func safetyLevel(for category: ScanCategory<JunkItem>) -> SafetyLevel {
        category.items.first?.safetyLevel ?? .safe
    }

    // MARK: - ScanModule conformance

    func startScan() async {
        scanState = .scanning(progress: .empty)
        results = []
        selectedItemIds = []
        selectedCategoryId = nil

        do {
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
        } catch is CancellationError {
            self.scanState = .idle
        } catch {
            self.scanState = .error(error.localizedDescription)
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

    var isCleaning: Bool {
        if case .inProgress = cleaningPhase { return true }
        return false
    }

    // MARK: - View helpers

    func beginScan() {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            await self?.startScan()
        }
    }

    // MARK: - Rich cleaning flow (UI)

    /// Entry point from the UI Clean button.
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
        // Brief delay so apps actually exit before we try to trash their files.
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

    func selectAllSafe() {
        for category in results where category.items.first?.safetyLevel == .safe {
            for item in category.items {
                selectedItemIds.insert(item.id)
            }
        }
    }

    func deselectAll() {
        selectedItemIds.removeAll()
    }

    func toggleCategory(id: String) {
        guard let category = results.first(where: { $0.id == id }) else { return }
        let allSelected = category.items.allSatisfy { selectedItemIds.contains($0.id) }
        if allSelected {
            for item in category.items {
                selectedItemIds.remove(item.id)
            }
        } else {
            for item in category.items {
                selectedItemIds.insert(item.id)
            }
        }
    }

    func toggleItem(id: UUID) {
        if selectedItemIds.contains(id) {
            selectedItemIds.remove(id)
        } else {
            selectedItemIds.insert(id)
        }
    }

    func returnToIdle() {
        scanTask?.cancel()
        scanTask = nil
        results = []
        selectedItemIds = []
        selectedCategoryId = nil
        scanState = .idle
    }

}
