import Foundation

// Conformed to by every cleanup/scan module's view model. The associated
// ResultType is a concrete struct conforming to ScanResult, so a generic
// ModuleView<M: ScanModule> can render any module without knowing the
// specific result shape.
//
// @MainActor: every conformer is a SwiftUI view model that touches @Published
// state from the main thread, so all method requirements are MainActor-isolated.
@MainActor
protocol ScanModule: ObservableObject {
    associatedtype ResultType: ScanResult

    var moduleInfo: ModuleInfo { get }
    var scanState: ScanState { get set }
    var results: [ScanCategory<ResultType>] { get set }

    var selectedItemIds: Set<UUID> { get set }
    var selectedCategoryId: String? { get set }
    var sortMode: SortMode { get set }

    var totalCleanableSize: Int64 { get }
    var selectedSize: Int64 { get }

    func startScan() async
    func cancelScan()
    func clean(items: [ResultType]) async throws
}

// Default implementations — every conformer gets these for free.
extension ScanModule {

    // MARK: Sizes

    var totalCleanableSize: Int64 {
        results.reduce(Int64(0)) { $0 + $1.totalSize }
    }

    var selectedSize: Int64 {
        results
            .flatMap { $0.items }
            .filter { selectedItemIds.contains($0.id) }
            .reduce(Int64(0)) { $0 + $1.size }
    }

    var selectedItems: [ResultType] {
        results.flatMap { $0.items }.filter { selectedItemIds.contains($0.id) }
    }

    // MARK: Categories

    var selectedCategory: ScanCategory<ResultType>? {
        guard let id = selectedCategoryId else { return nil }
        return results.first { $0.id == id }
    }

    var sortedCategories: [ScanCategory<ResultType>] {
        switch sortMode {
        case .size: return results.sorted { $0.totalSize > $1.totalSize }
        case .name: return results.sorted { $0.title < $1.title }
        }
    }

    func sortedItems(in category: ScanCategory<ResultType>) -> [ResultType] {
        switch sortMode {
        case .size: return category.items.sorted { $0.size > $1.size }
        case .name: return category.items.sorted { $0.name < $1.name }
        }
    }

    func selectionState(for category: ScanCategory<ResultType>) -> SelectionState {
        let total = category.items.count
        guard total > 0 else { return .none }
        let selected = category.items.filter { selectedItemIds.contains($0.id) }.count
        if selected == 0 { return .none }
        if selected == total { return .all }
        return .partial
    }

    func safetyLevel(for category: ScanCategory<ResultType>) -> SafetyLevel {
        category.items.first?.safetyLevel ?? .safe
    }

    // MARK: Selection

    func toggleItem(id: UUID) {
        if selectedItemIds.contains(id) {
            selectedItemIds.remove(id)
        } else {
            selectedItemIds.insert(id)
        }
    }

    func toggleCategory(id: String) {
        guard let category = results.first(where: { $0.id == id }) else { return }
        let allSelected = category.items.allSatisfy { selectedItemIds.contains($0.id) }
        if allSelected {
            for item in category.items { selectedItemIds.remove(item.id) }
        } else {
            for item in category.items { selectedItemIds.insert(item.id) }
        }
    }

    func deselectAll() {
        selectedItemIds.removeAll()
    }

    func selectAllSafe() {
        for category in results where category.items.first?.safetyLevel == .safe {
            for item in category.items {
                selectedItemIds.insert(item.id)
            }
        }
    }

    // MARK: State helpers

    var isScanning: Bool {
        if case .scanning = scanState { return true }
        return false
    }

    var hasResults: Bool {
        scanState == .complete && !results.isEmpty
    }

    /// Synchronous helper for views: kicks off the async startScan in a Task.
    /// Implementations that need cancellation should track their own internal
    /// task inside startScan/cancelScan.
    func beginScan() {
        Task { await startScan() }
    }

    /// Resets state back to landing.
    func returnToIdle() {
        cancelScan()
        scanState = .idle
        results = []
        selectedItemIds = []
        selectedCategoryId = nil
    }
}
