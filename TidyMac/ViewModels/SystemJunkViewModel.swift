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
    @Published private(set) var isCleaning: Bool = false
    @Published var alertMessage: String?

    private var scanTask: Task<Void, Never>?
    private let scanner = SystemJunkScanner()

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

        isCleaning = true
        defer { isCleaning = false }

        let urls = items.map { $0.path }
        let trashed = await Self.recycle(urls: urls)
        let removedURLs = Set(trashed.keys)

        let cleanedItemIds: Set<UUID> = Set(
            items.filter { removedURLs.contains($0.path) }.map { $0.id }
        )

        for catIdx in results.indices {
            results[catIdx].items.removeAll { cleanedItemIds.contains($0.id) }
        }
        results.removeAll { $0.items.isEmpty }
        selectedItemIds.subtract(cleanedItemIds)

        if let id = selectedCategoryId, !results.contains(where: { $0.id == id }) {
            selectedCategoryId = sortedCategories.first?.id
        }

        if cleanedItemIds.count < items.count {
            let failed = items.count - cleanedItemIds.count
            alertMessage = "Removed \(cleanedItemIds.count) item\(cleanedItemIds.count == 1 ? "" : "s"). \(failed) couldn't be moved to Trash."
        }
    }

    // MARK: - View helpers

    func beginScan() {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            await self?.startScan()
        }
    }

    func cleanSelected() async {
        let items = selectedItems
        guard !items.isEmpty else { return }
        do {
            try await clean(items: items)
        } catch {
            alertMessage = error.localizedDescription
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

    // MARK: - Internal

    private static func recycle(urls: [URL]) async -> [URL: URL] {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle(urls) { newURLs, _ in
                continuation.resume(returning: newURLs)
            }
        }
    }
}
