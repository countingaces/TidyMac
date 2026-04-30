import Foundation
import AppKit

@MainActor
final class LargeFilesViewModel: ObservableObject {
    enum ScanPhase: Equatable {
        case idle
        case scanning(LargeFileScanner.Progress)
        case complete
        case error(String)
    }

    enum SortMode: String, CaseIterable, Identifiable {
        case size, name, date
        var id: String { rawValue }
        var label: String {
            switch self {
            case .size: return "Sort by Size"
            case .name: return "Sort by Name"
            case .date: return "Sort by Date"
            }
        }
    }

    enum CleaningPhase {
        case idle
        case inProgress(CleaningService.Progress)
        case finished(CleaningService.CleaningResult)
    }

    // MARK: - Published state

    @Published var phase: ScanPhase = .idle
    @Published private(set) var files: [LargeFile] = []
    @Published var selectedIds: Set<UUID> = []
    @Published var activeKindFilter: FileKind?
    @Published var activeSizeFilter: SizeCategory?
    @Published var activeAccessFilter: AccessCategory?
    @Published var searchQuery: String = ""
    @Published var sortMode: SortMode = .size
    @Published var cleaningPhase: CleaningPhase = .idle
    @Published var alertMessage: String?

    // MARK: - Internal

    private let scanner = LargeFileScanner()
    private let cleaningService = CleaningService()
    private var scanTask: Task<Void, Never>?
    private var cleaningTask: Task<Void, Never>?

    // MARK: - Convenience

    var hasResults: Bool {
        if case .complete = phase { return true }
        return false
    }

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    var totalSize: Int64 {
        files.reduce(Int64(0)) { $0 + $1.size }
    }

    var selectedSize: Int64 {
        files.filter { selectedIds.contains($0.id) }.reduce(Int64(0)) { $0 + $1.size }
    }

    var hasActiveFilter: Bool {
        activeKindFilter != nil || activeSizeFilter != nil || activeAccessFilter != nil
    }

    /// Files matching every active filter + search. The order applied
    /// here drives the right-pane list; facet counts use slightly
    /// different bases so each filter sidebar group reflects the
    /// other active filters but not itself (dependent facet counts).
    var filteredFiles: [LargeFile] {
        applySort(applyFilters(files, includingKind: true, includingSize: true, includingAccess: true))
    }

    /// One-line headline for the active filter, shown at the top of
    /// the right-pane list.
    var filterTitle: String {
        var parts: [String] = []
        if let kind = activeKindFilter { parts.append(kind.displayName) }
        if let size = activeSizeFilter { parts.append(size.displayName) }
        if let access = activeAccessFilter { parts.append(access.displayName) }
        if parts.isEmpty { return "All Files" }
        return parts.joined(separator: " · ")
    }

    // MARK: - Filter facet counts (dependent)

    struct FacetCount: Identifiable, Hashable {
        let key: String
        let count: Int
        let totalSize: Int64
        var id: String { key }
    }

    /// Per-kind counts, holding kind variable but applying all OTHER
    /// active filters. So selecting "Movies" doesn't zero out the size
    /// facet — instead the size facet shows movie sizes.
    func count(for kind: FileKind) -> FacetCount {
        let base = applyFilters(files, includingKind: false, includingSize: true, includingAccess: true)
        let matched = base.filter { $0.kind == kind }
        return FacetCount(key: kind.rawValue, count: matched.count,
                          totalSize: matched.reduce(0) { $0 + $1.size })
    }

    func count(for size: SizeCategory) -> FacetCount {
        let base = applyFilters(files, includingKind: true, includingSize: false, includingAccess: true)
        let matched = base.filter { $0.sizeCategory == size }
        return FacetCount(key: size.rawValue, count: matched.count,
                          totalSize: matched.reduce(0) { $0 + $1.size })
    }

    func count(for access: AccessCategory) -> FacetCount {
        let base = applyFilters(files, includingKind: true, includingSize: true, includingAccess: false)
        let matched = base.filter { $0.accessCategory == access }
        return FacetCount(key: access.rawValue, count: matched.count,
                          totalSize: matched.reduce(0) { $0 + $1.size })
    }

    // MARK: - Filter actions

    func setKindFilter(_ kind: FileKind?) {
        // Toggle off if user clicks the active one again.
        activeKindFilter = (kind == activeKindFilter) ? nil : kind
    }

    func setSizeFilter(_ size: SizeCategory?) {
        activeSizeFilter = (size == activeSizeFilter) ? nil : size
    }

    func setAccessFilter(_ access: AccessCategory?) {
        activeAccessFilter = (access == activeAccessFilter) ? nil : access
    }

    func clearAllFilters() {
        activeKindFilter = nil
        activeSizeFilter = nil
        activeAccessFilter = nil
        searchQuery = ""
    }

    // MARK: - Selection

    func toggleSelection(id: UUID) {
        if selectedIds.contains(id) { selectedIds.remove(id) }
        else { selectedIds.insert(id) }
    }

    func selectAllVisible() {
        for file in filteredFiles { selectedIds.insert(file.id) }
    }

    func deselectAll() {
        selectedIds.removeAll()
    }

    // MARK: - Scan

    func startScan() {
        scanTask?.cancel()
        files = []
        selectedIds = []
        phase = .scanning(LargeFileScanner.Progress(filesFound: 0, totalSize: 0, currentDirectory: "Starting…"))

        scanTask = Task { [scanner] in
            let stream = scanner.scan { progress in
                Task { @MainActor [weak self] in
                    self?.applyProgress(progress)
                }
            }
            for await file in stream {
                if Task.isCancelled { break }
                files.append(file)
            }
            if Task.isCancelled { return }
            phase = .complete
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        // Whatever we collected so far is still useful — flip to
        // .complete so the user can interact with what's there.
        phase = .complete
    }

    private func applyProgress(_ progress: LargeFileScanner.Progress) {
        phase = .scanning(progress)
    }

    // MARK: - Removal

    func requestRemoval() {
        let toRemove = files.filter { selectedIds.contains($0.id) }
        guard !toRemove.isEmpty else { return }
        cleaningTask?.cancel()
        cleaningTask = Task { [cleaningService] in
            let items = toRemove.map { ScanItem(name: $0.name, path: $0.url, size: $0.size) }
            cleaningPhase = .inProgress(CleaningService.Progress(
                currentItemName: items.first?.name ?? "",
                itemsCompleted: 0,
                totalItems: items.count,
                sizeFreedSoFar: 0
            ))
            let result = await cleaningService.clean(items: items) { progress in
                Task { @MainActor [weak self] in
                    self?.cleaningPhase = .inProgress(progress)
                }
            }
            cleaningPhase = .finished(result)
            // Drop removed files from our state so the UI updates.
            let cleanedURLs = Set(result.log
                .filter { $0.success }
                .map { $0.path })
            files.removeAll { cleanedURLs.contains($0.url) }
            selectedIds.subtract(toRemove.map { $0.id })
        }
    }

    func cancelCleaning() {
        cleaningTask?.cancel()
    }

    func dismissCleaningResult() {
        cleaningPhase = .idle
    }

    // MARK: - Internal helpers

    /// Applies whichever filter axes are active. The flags let facet
    /// counters compute "what would be selected if I varied THIS
    /// dimension" without copy/pasting the predicate three times.
    private func applyFilters(
        _ source: [LargeFile],
        includingKind: Bool,
        includingSize: Bool,
        includingAccess: Bool
    ) -> [LargeFile] {
        var result = source
        if includingKind, let kind = activeKindFilter {
            result = result.filter { $0.kind == kind }
        }
        if includingSize, let size = activeSizeFilter {
            result = result.filter { $0.sizeCategory == size }
        }
        if includingAccess, let access = activeAccessFilter {
            result = result.filter { $0.accessCategory == access }
        }
        if !searchQuery.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
        }
        return result
    }

    private func applySort(_ source: [LargeFile]) -> [LargeFile] {
        switch sortMode {
        case .size:
            return source.sorted { $0.size > $1.size }
        case .name:
            return source.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .date:
            return source.sorted {
                ($0.effectiveDate ?? .distantPast) > ($1.effectiveDate ?? .distantPast)
            }
        }
    }
}

// MARK: - CleaningService adapter

/// Minimal ScanResult conformance so CleaningService (which is generic
/// over ScanResult) can clean LargeFile selections without LargeFile
/// itself having to implement the full ScanResult contract.
private struct ScanItem: ScanResult {
    let id: UUID = UUID()
    let name: String
    let path: URL
    let size: Int64
    let safetyLevel: SafetyLevel = .safe
    let categoryId: String = "large-files"
}
