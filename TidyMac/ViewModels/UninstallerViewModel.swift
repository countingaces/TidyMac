import Foundation
import SwiftUI
import AppKit

@MainActor
final class UninstallerViewModel: ObservableObject {

    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    enum SortMode: String, CaseIterable, Identifiable {
        case lastUsed, name, size, category
        var id: String { rawValue }
        var label: String {
            switch self {
            case .lastUsed: return "Last Used"
            case .name:     return "Name"
            case .size:     return "Size"
            case .category: return "Category"
            }
        }
    }

    enum FilterMode: String, CaseIterable, Identifiable {
        case all, appStore, thirdParty, unused
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all:        return "All"
            case .appStore:   return "App Store"
            case .thirdParty: return "Third Party"
            case .unused:     return "Unused"
            }
        }
    }

    enum CleaningPhase {
        case idle
        case awaitingQuitDecision
        case inProgress(CleaningService.Progress)
        case finished(CleaningService.CleaningResult)
    }

    let moduleInfo = ModuleInfo(
        id: "uninstaller",
        title: "Uninstaller",
        description: "Cleanly remove apps and the leftover files they leave behind",
        icon: "xmark.app.fill",
        colorTheme: .applications,
        features: [
            ModuleInfo.Feature(
                icon: "magnifyingglass",
                title: "Find every leftover",
                subtitle: "Scans 12 Library locations for files apps leave behind"
            ),
            ModuleInfo.Feature(
                icon: "checkmark.shield.fill",
                title: "Confidence-rated matches",
                subtitle: "Auto-selects exact bundle-id matches; flags uncertain ones for review"
            )
        ]
    )

    // MARK: - Published state

    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var apps: [AppInfo] = []

    @Published var searchText: String = ""
    @Published var sortMode: SortMode = .lastUsed
    @Published var filterMode: FilterMode = .all

    @Published var selectedAppIds: Set<String> = []
    @Published var focusedAppId: String?

    @Published private(set) var remnantsByAppId: [String: [AppRemnant]] = [:]
    @Published private(set) var scanningAppIds: Set<String> = []

    /// Per-app, the set of remnant ids currently checked in the detail sheet.
    /// Auto-populated with high-confidence matches when remnants first scan.
    @Published var selectedRemnantIds: [String: Set<UUID>] = [:]

    @Published var cleaningPhase: CleaningPhase = .idle
    @Published var runningAppsToQuit: [NSRunningApplication] = []
    @Published var alertMessage: String?

    private let discoveryService = AppDiscoveryService()
    private let remnantScanner = RemnantScanner()
    private let cleaningService = CleaningService()
    private var cleanTask: Task<Void, Never>?

    // MARK: - Discovery

    func loadApps() async {
        loadState = .loading
        let found = await discoveryService.discoverApps()
        apps = found
        loadState = .loaded
    }

    // MARK: - Lazy remnant scanning

    func scanRemnants(for app: AppInfo) {
        guard remnantsByAppId[app.id] == nil else { return }
        guard !scanningAppIds.contains(app.id) else { return }

        scanningAppIds.insert(app.id)
        Task { [weak self] in
            guard let self else { return }
            let remnants = await self.remnantScanner.scan(for: app)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.remnantsByAppId[app.id] = remnants
                self.scanningAppIds.remove(app.id)
                // Auto-select high-confidence matches.
                let auto = remnants
                    .filter { $0.matchConfidence.isAutoSelected }
                    .map { $0.id }
                self.selectedRemnantIds[app.id] = Set(auto)
            }
        }
    }

    func remnants(for appId: String) -> [AppRemnant] {
        remnantsByAppId[appId] ?? []
    }

    func remnantsSize(for appId: String) -> Int64? {
        guard let remnants = remnantsByAppId[appId] else { return nil }
        return remnants.reduce(Int64(0)) { $0 + $1.size }
    }

    // MARK: - Filtering / sorting

    var visibleApps: [AppInfo] {
        let filtered = apps.filter { matches(filter: $0) && matches(search: $0) }
        return sorted(filtered)
    }

    private func matches(filter app: AppInfo) -> Bool {
        switch filterMode {
        case .all:        return true
        case .appStore:   return app.category == .appStore
        case .thirdParty: return app.category == .thirdParty
        case .unused:
            guard let last = app.lastUsedDate else { return true }
            let cutoff = Date().addingTimeInterval(-90 * 24 * 60 * 60)
            return last < cutoff
        }
    }

    private func matches(search app: AppInfo) -> Bool {
        guard !searchText.isEmpty else { return true }
        let needle = searchText.lowercased()
        return app.name.lowercased().contains(needle)
            || app.id.lowercased().contains(needle)
    }

    private func sorted(_ list: [AppInfo]) -> [AppInfo] {
        switch sortMode {
        case .name:
            return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .size:
            return list.sorted { $0.totalSize > $1.totalSize }
        case .category:
            return list.sorted { $0.category.displayName < $1.category.displayName }
        case .lastUsed:
            // Apps never used (nil) sort first — most likely uninstall candidates.
            return list.sorted { (a, b) in
                switch (a.lastUsedDate, b.lastUsedDate) {
                case (nil, nil): return a.name < b.name
                case (nil, _):   return true
                case (_, nil):   return false
                case let (.some(da), .some(db)): return da < db
                }
            }
        }
    }

    // MARK: - Selection

    func toggleApp(id: String) {
        if selectedAppIds.contains(id) {
            selectedAppIds.remove(id)
        } else {
            selectedAppIds.insert(id)
        }
    }

    func toggleRemnant(id: UUID, for appId: String) {
        var current = selectedRemnantIds[appId] ?? []
        if current.contains(id) {
            current.remove(id)
        } else {
            current.insert(id)
        }
        selectedRemnantIds[appId] = current
    }

    func selectAllSafeRemnants(for appId: String) {
        let auto = remnants(for: appId)
            .filter { $0.matchConfidence.isAutoSelected }
            .map { $0.id }
        selectedRemnantIds[appId] = Set(auto)
    }

    func selectAllRemnants(for appId: String) {
        selectedRemnantIds[appId] = Set(remnants(for: appId).map { $0.id })
    }

    func deselectAllRemnants(for appId: String) {
        selectedRemnantIds[appId] = []
    }

    // MARK: - Selected apps / focused app

    var selectedApps: [AppInfo] {
        apps.filter { selectedAppIds.contains($0.id) }
    }

    var focusedApp: AppInfo? {
        guard let id = focusedAppId else { return nil }
        return apps.first { $0.id == id }
    }

    var selectedTotalSize: Int64 {
        selectedApps.reduce(Int64(0)) { acc, app in
            let bundle = app.bundleSize
            let chosen = selectedRemnantIds[app.id] ?? defaultSelectedRemnantIds(for: app.id)
            let remnants = remnantsByAppId[app.id] ?? []
            let remnantBytes = remnants
                .filter { chosen.contains($0.id) }
                .reduce(Int64(0)) { $0 + $1.size }
            return acc + bundle + remnantBytes
        }
    }

    private func defaultSelectedRemnantIds(for appId: String) -> Set<UUID> {
        Set(remnants(for: appId)
            .filter { $0.matchConfidence.isAutoSelected }
            .map { $0.id })
    }

    // MARK: - Uninstall flow

    func requestUninstall() {
        let conflicting = NSWorkspace.shared.runningApplications.filter { app in
            guard let id = app.bundleIdentifier else { return false }
            return selectedAppIds.contains(id)
        }
        runningAppsToQuit = conflicting
        if conflicting.isEmpty {
            beginUninstall()
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
                self?.beginUninstall()
            }
        }
    }

    func ignoreAndContinue() {
        beginUninstall()
    }

    func cancelPreflight() {
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
        // Refresh app list — anything we successfully removed is gone now.
        Task { await loadApps() }
    }

    private func beginUninstall() {
        let items = buildUninstallItems()
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
                self.runningAppsToQuit = []
                self.cleaningPhase = .finished(result)
            }
        }
    }

    /// Compose the trash list from selected apps + their selected remnants.
    private func buildUninstallItems() -> [JunkItem] {
        var items: [JunkItem] = []
        for app in selectedApps {
            // The .app bundle itself
            items.append(JunkItem(
                name: "\(app.name) \(app.version) (app bundle)",
                path: app.bundlePath,
                size: app.bundleSize,
                safetyLevel: .cautious,
                categoryId: "uninstall.bundle",
                appBundleId: app.id
            ))

            // Selected remnants for this app
            let chosen = selectedRemnantIds[app.id] ?? defaultSelectedRemnantIds(for: app.id)
            let remnants = remnantsByAppId[app.id] ?? []
            for remnant in remnants where chosen.contains(remnant.id) {
                items.append(JunkItem(
                    name: remnant.path.lastPathComponent,
                    path: remnant.path,
                    size: remnant.size,
                    safetyLevel: remnant.category.safetyLevel,
                    categoryId: "uninstall.remnant.\(remnant.category.rawValue)",
                    appBundleId: app.id
                ))
            }
        }
        return items
    }
}
