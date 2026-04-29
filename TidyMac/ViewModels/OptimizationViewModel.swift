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
    /// Items currently mid-mutation (toggle running, password prompt up).
    /// The view dims toggles for these to prevent double-clicks while the
    /// admin sheet is showing.
    @Published var pendingItemIds: Set<String> = []
    /// Items checked for batch removal in the bottom action bar.
    @Published var selectedRemovalIds: Set<String> = []

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

    func refreshHungApps() async {
        let scanner = OptimizationScanner()
        let fresh = await scanner.scan()
        // Replace only the hung-app rows; keep agents/login items unchanged
        // so the user's selection state on those isn't reset.
        items.removeAll { $0.type == .hungApp }
        items.append(contentsOf: fresh.filter { $0.type == .hungApp })
    }

    /// Force Quit the apps the user has checked in the Hung Applications
    /// tab. Uses NSRunningApplication.forceTerminate (SIGKILL after a
    /// short polite SIGTERM grace period) — works without admin since
    /// scanHungApps already filters to processes owned by the current user.
    func forceQuitSelected() {
        let toKill = items.filter {
            selectedRemovalIds.contains($0.id) && $0.type == .hungApp
        }
        guard !toKill.isEmpty else { return }

        for item in toKill {
            guard let pid = item.processIdentifier,
                  let app = NSRunningApplication(processIdentifier: pid)
            else { continue }
            app.forceTerminate()
        }

        // Optimistically drop the killed rows. The next refresh will
        // confirm they're gone (or surface them again if they survived).
        let killedIds = Set(toKill.map(\.id))
        items.removeAll { killedIds.contains($0.id) }
        selectedRemovalIds.subtract(killedIds)
    }

    // MARK: - Toggle (enable/disable)

    func toggleItem(id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        // Hung apps don't have a plist to toggle — they're force-quit, not
        // disabled. Guard here even though the UI hides the toggle for them.
        guard item.type != .hungApp else { return }
        guard item.plistURL != nil else { return }
        guard !pendingItemIds.contains(id) else { return }

        pendingItemIds.insert(id)
        let willEnable = !item.isEnabled
        Task {
            defer { pendingItemIds.remove(id) }
            await applyToggle(item: item, willEnable: willEnable)
        }
    }

    private func applyToggle(item: StartupItem, willEnable: Bool) async {
        do {
            if item.requiresAdmin {
                try await applyAdminToggle(item: item, willEnable: willEnable)
            } else {
                try setAgentDisabled(plistURL: item.plistURL!, disabled: !willEnable)
                try runLaunchctl(
                    enable: willEnable,
                    label: launchctlLabel(from: item),
                    domain: launchctlDomain(for: item)
                )
            }
            // Re-find the item by id — the array may have shifted while we
            // were waiting on the password prompt.
            if let nowIdx = items.firstIndex(where: { $0.id == item.id }) {
                items[nowIdx] = with(items[nowIdx], isEnabled: willEnable)
            }
        } catch MaintenanceError.authorizationCancelled {
            // User clicked Cancel on the password prompt — silent no-op.
        } catch {
            alertMessage = "Couldn't \(willEnable ? "enable" : "disable") \(item.name): \(error.localizedDescription)"
        }
    }

    /// Combines the plist mutation and the launchctl call into one shell
    /// invocation so the user sees a single password prompt per click.
    /// Strict ordering with `set -e`: plutil failure aborts the script
    /// (so we don't claim success when the underlying file wasn't touched).
    /// launchctl warnings ("service is already disabled") stay swallowed —
    /// the plist's Disabled key is the source of truth.
    private func applyAdminToggle(item: StartupItem, willEnable: Bool) async throws {
        guard let plistURL = item.plistURL else { return }
        let plistArg = quotedShellArg(plistURL.path)
        let label = launchctlLabel(from: item)
        let domain = launchctlDomain(for: item)

        // Disable: plutil MUST succeed (otherwise nothing actually changed).
        // Enable: plutil -remove can fail if the key isn't present, that's
        //         fine — squash with `|| :`.
        let plistCmd = willEnable
            ? "/usr/bin/plutil -remove Disabled \(plistArg) 2>/dev/null || :"
            : "/usr/bin/plutil -replace Disabled -bool YES \(plistArg)"
        let launchctlCmd = "/bin/launchctl \(willEnable ? "enable" : "disable") \(domain)/\(label) 2>/dev/null || :"
        let script = "set -e; \(plistCmd); \(launchctlCmd)"

        _ = try await runShellAsAdmin(script)

        // Belt-and-suspenders: re-read the plist and confirm the Disabled
        // flag actually took. If plutil silently no-op'd or the file got
        // restored by a watchdog, the user needs to know.
        if try !verifyDisabledState(plistURL: plistURL, expectedDisabled: !willEnable) {
            throw MaintenanceError.commandFailed(
                "The change ran without errors but \(plistURL.lastPathComponent) still reports the old state. The agent's parent app may be restoring the plist on a watchdog."
            )
        }
    }

    private func verifyDisabledState(plistURL: URL, expectedDisabled: Bool) throws -> Bool {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            // If we can't read the file at all, assume the worst.
            return false
        }
        let disabled = (plist["Disabled"] as? Bool) ?? false
        return disabled == expectedDisabled
    }

    // MARK: - Removal

    /// Remove a broken or orphaned agent. User-scoped plists go to the
    /// Trash so the user can recover them; admin-scoped (root-owned) plists
    /// are rm'd via osascript-elevated shell because Trash can't accept
    /// root-owned files anyway.
    func removeItem(id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        guard item.plistURL != nil else { return }
        guard !pendingItemIds.contains(id) else { return }

        pendingItemIds.insert(id)
        Task {
            defer { pendingItemIds.remove(id) }
            await applyRemove(item: item)
        }
    }

    private func applyRemove(item: StartupItem) async {
        do {
            if item.requiresAdmin {
                try await applyAdminRemove(items: [item])
            } else {
                guard let plistURL = item.plistURL else { return }
                try? runLaunchctl(
                    enable: false,
                    label: launchctlLabel(from: item),
                    domain: launchctlDomain(for: item)
                )
                var trashed: NSURL?
                try FileManager.default.trashItem(at: plistURL, resultingItemURL: &trashed)
            }
            items.removeAll { $0.id == item.id }
            selectedRemovalIds.remove(item.id)
        } catch MaintenanceError.authorizationCancelled {
            // No-op on user cancel.
        } catch {
            alertMessage = "Couldn't remove \(item.name): \(error.localizedDescription)"
        }
    }

    /// One osascript invocation, one password prompt — even if multiple
    /// admin-owned plists are being removed in one batch.
    private func applyAdminRemove(items: [StartupItem]) async throws {
        var commands: [String] = []
        for item in items {
            guard let plistURL = item.plistURL else { continue }
            let label = launchctlLabel(from: item)
            let domain = launchctlDomain(for: item)
            commands.append("/bin/launchctl bootout \(domain)/\(label) 2>/dev/null || true")
            commands.append("/bin/rm -f \(quotedShellArg(plistURL.path))")
        }
        guard !commands.isEmpty else { return }
        _ = try await runShellAsAdmin(commands.joined(separator: "; "))
    }

    // MARK: - Batch selection

    func toggleSelection(id: String) {
        if selectedRemovalIds.contains(id) {
            selectedRemovalIds.remove(id)
        } else {
            selectedRemovalIds.insert(id)
        }
    }

    func deselectAll() {
        selectedRemovalIds.removeAll()
    }

    /// Bottom-bar Remove. Same admin-batching as removeAllBroken: non-
    /// admin items trash one by one (no prompt), admin items get bundled
    /// into a single elevated shell so the user authenticates once
    /// regardless of how many root-owned plists they checked.
    func removeSelected() {
        let toRemove = items.filter { selectedRemovalIds.contains($0.id) }
        let admin = toRemove.filter { $0.requiresAdmin }
        let nonAdmin = toRemove.filter { !$0.requiresAdmin }

        for item in nonAdmin {
            removeItem(id: item.id)
        }

        if !admin.isEmpty {
            let adminIds = admin.map(\.id)
            for id in adminIds { pendingItemIds.insert(id) }
            Task {
                defer { adminIds.forEach { self.pendingItemIds.remove($0) } }
                do {
                    try await applyAdminRemove(items: admin)
                    let removed = Set(adminIds)
                    items.removeAll { removed.contains($0.id) }
                    selectedRemovalIds.subtract(removed)
                } catch MaintenanceError.authorizationCancelled {
                    // No-op on user cancel.
                } catch {
                    alertMessage = "Couldn't remove items: \(error.localizedDescription)"
                }
            }
        } else {
            // Non-admin removals already cleared themselves; just sweep.
            selectedRemovalIds.removeAll()
        }
    }

    /// "Remove all broken" tool. Splits broken items into admin and non-
    /// admin buckets; non-admin go to the Trash one by one (no prompt),
    /// admin entries are bundled into a single elevated shell so the user
    /// sees exactly one password prompt no matter how many were broken.
    func removeAllBroken() {
        let broken = items.filter { $0.isIssue }
        let admin = broken.filter { $0.requiresAdmin }
        let nonAdmin = broken.filter { !$0.requiresAdmin }

        for item in nonAdmin {
            removeItem(id: item.id)
        }

        guard !admin.isEmpty else { return }
        let adminIds = admin.map(\.id)
        for id in adminIds { pendingItemIds.insert(id) }
        Task {
            defer { adminIds.forEach { self.pendingItemIds.remove($0) } }
            do {
                try await applyAdminRemove(items: admin)
                let removed = Set(adminIds)
                items.removeAll { removed.contains($0.id) }
            } catch MaintenanceError.authorizationCancelled {
                // No-op on user cancel.
            } catch {
                alertMessage = "Couldn't remove broken agents: \(error.localizedDescription)"
            }
        }
    }

    /// Tools menu entry point. Disables every user-scoped Launch Agent
    /// that's currently enabled. Apple agents are already filtered out at
    /// scan time; admin-scoped items aren't included because batching them
    /// would require a separate elevated invocation — Tools-menu intent is
    /// "no surprises", so we stick to the no-prompt path here.
    func disableAllNonEssential() {
        let candidates = items.filter {
            $0.source == .userLaunchAgent && $0.isEnabled
        }
        for item in candidates {
            toggleItem(id: item.id)
        }
    }

    // MARK: - launchctl plumbing

    /// `launchctl <enable|disable> <domain>/<label>` persists the change
    /// across reboots. The Disabled key in the plist is the real source of
    /// truth — launchctl just keeps the in-memory state in sync.
    private func runLaunchctl(enable: Bool, label: String, domain: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = [
            enable ? "enable" : "disable",
            "\(domain)/\(label)"
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        // Non-zero termination is OK ("Service is already disabled" etc.)
    }

    /// Maps an item's source to launchctl's domain target. User agents go
    /// to user/<UID>; system agents in /Library/LaunchAgents run as the
    /// GUI user (gui/<UID>); system daemons run as root (system).
    private func launchctlDomain(for item: StartupItem) -> String {
        let uid = getuid()
        switch item.source {
        case .userLaunchAgent: return "user/\(uid)"
        case .systemLaunchAgent: return "gui/\(uid)"
        case .systemLaunchDaemon: return "system"
        default: return "user/\(uid)"
        }
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

    /// Single-quote a shell argument while neutralizing any embedded
    /// single quotes via the standard '\'' trick. Belt-and-suspenders for
    /// paths with spaces or punctuation.
    private func quotedShellArg(_ s: String) -> String {
        "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
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
            processIdentifier: item.processIdentifier
        )
    }
}
