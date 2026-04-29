import Foundation
import AppKit

@MainActor
final class OptimizationViewModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    @Published var loadState: LoadState = .idle
    @Published var items: [StartupItem] = []
    @Published var selectedCategory: StartupItem.Category = .launchAgents
    @Published var alertMessage: String?

    let theme: ColorTheme = .optimization
    private let scanner = OptimizationScanner()

    var brokenAgentCount: Int {
        items.filter { $0.isIssue }.count
    }

    func items(in category: StartupItem.Category) -> [StartupItem] {
        items
            .filter { StartupItem.category(for: $0.source, type: $0.type) == category }
            .sorted { sortKey(for: $0) < sortKey(for: $1) }
    }

    private func sortKey(for item: StartupItem) -> String {
        // Issues bubble to the top. Inside each tier, alphabetize.
        let issueTier = item.isIssue ? "0" : "1"
        return "\(issueTier)-\(item.name.lowercased())"
    }

    func count(in category: StartupItem.Category) -> Int {
        items(in: category).count
    }

    // MARK: - Load

    func load() async {
        loadState = .loading
        items = await scanner.scan()
        loadState = .loaded
    }

    func refreshHeavyConsumers() async {
        let scanner = OptimizationScanner()
        let fresh = await scanner.scan()
        // Replace only the running-process rows; keep agents/login items
        // unchanged so the user's selection state isn't reset.
        items.removeAll { $0.source == .runningProcess }
        items.append(contentsOf: fresh.filter { $0.source == .runningProcess })
    }

    // MARK: - Toggle (enable/disable)

    func toggleItem(id: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[idx]

        // Heavy consumers can't be "disabled" from this UI — they're live
        // processes, not configured services. The toggle is hidden for them.
        guard item.source != .runningProcess else { return }

        // System agents need root; we'd need a privileged helper. Surface a
        // friendly note instead of silently failing.
        if item.requiresAdmin {
            alertMessage = "System Launch Agents require admin privileges to modify. This will be supported in a future build via a privileged helper."
            return
        }

        guard item.source == .userLaunchAgent, let plistURL = item.plistURL else {
            return
        }

        let willEnable = !item.isEnabled
        do {
            try setAgentDisabled(plistURL: plistURL, disabled: !willEnable)
            try runLaunchctl(enable: willEnable, label: launchctlLabel(from: item))
            items[idx] = with(item, isEnabled: willEnable)
        } catch {
            alertMessage = "Couldn't \(willEnable ? "enable" : "disable") \(item.name): \(error.localizedDescription)"
        }
    }

    /// Remove a broken or orphaned agent. Move the plist to Trash so the
    /// user can recover it from there if it turns out something needed it.
    func removeItem(id: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[idx]

        if item.requiresAdmin {
            alertMessage = "System Launch Agents require admin privileges to remove. This will be supported in a future build via a privileged helper."
            return
        }

        guard let plistURL = item.plistURL else { return }

        // Stop the running job first if it's currently loaded; otherwise
        // launchd may keep the process around after we delete the plist.
        try? runLaunchctl(enable: false, label: launchctlLabel(from: item))

        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(at: plistURL, resultingItemURL: &trashed)
            items.remove(at: idx)
        } catch {
            alertMessage = "Couldn't remove \(item.name): \(error.localizedDescription)"
        }
    }

    func removeAllBroken() {
        let brokenIds = items.filter { $0.isIssue && !$0.requiresAdmin }.map { $0.id }
        for id in brokenIds {
            removeItem(id: id)
        }
    }

    /// Tools menu entry point. Disables every user-scoped Launch Agent
    /// that's currently enabled. Apple agents are already filtered out at
    /// scan time; system agents skip themselves because they need admin.
    func disableAllNonEssential() {
        let candidates = items.filter {
            $0.source == .userLaunchAgent && $0.isEnabled
        }
        for item in candidates {
            toggleItem(id: item.id)
        }
    }

    // MARK: - launchctl plumbing

    /// `launchctl bootout user/$UID/<label>` immediately stops a running
    /// job; `enable` flips it back on. We use the higher-level `disable`/
    /// `enable` verbs which persist across reboots.
    private func runLaunchctl(enable: Bool, label: String) throws {
        let uid = getuid()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = [
            enable ? "enable" : "disable",
            "user/\(uid)/\(label)"
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        // Non-zero termination is OK (e.g. "Service is already disabled");
        // the file-level Disabled key is the real source of truth.
    }

    private func launchctlLabel(from item: StartupItem) -> String {
        // The id we generate is "agent::source::label" — strip the prefix.
        if let range = item.id.range(of: "::", options: .backwards) {
            return String(item.id[range.upperBound...])
        }
        return item.name
    }

    /// Toggles the `Disabled` key in the agent's plist so the change
    /// survives a reboot. launchctl alone only affects the current session.
    private func setAgentDisabled(plistURL: URL, disabled: Bool) throws {
        var plist: [String: Any]
        if let data = try? Data(contentsOf: plistURL),
           let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            plist = parsed
        } else {
            plist = [:]
        }

        if disabled {
            plist["Disabled"] = true
        } else {
            plist.removeValue(forKey: "Disabled")
        }

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: plistURL, options: .atomic)
    }

    private func with(_ item: StartupItem, isEnabled: Bool) -> StartupItem {
        StartupItem(
            id: item.id,
            name: item.name,
            type: item.type,
            source: item.source,
            executablePath: item.executablePath,
            parentAppBundleId: item.parentAppBundleId,
            icon: item.icon,
            isEnabled: isEnabled,
            isExecutableMissing: item.isExecutableMissing,
            isParentAppMissing: item.isParentAppMissing,
            keepAlive: item.keepAlive,
            runAtLoad: item.runAtLoad,
            requiresAdmin: item.requiresAdmin,
            plistURL: item.plistURL,
            cpuPercent: item.cpuPercent,
            memoryMB: item.memoryMB
        )
    }
}
