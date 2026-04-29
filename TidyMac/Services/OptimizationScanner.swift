import Foundation
import AppKit
import ServiceManagement

/// Inspects everything macOS auto-starts: Launch Agents (user + system),
/// Login Items registered via SMAppService, and a live snapshot of the
/// heaviest CPU/memory consumers right now.
///
/// Read-only. Mutations (enable/disable/remove) live on OptimizationViewModel.
struct OptimizationScanner: Sendable {

    func scan() async -> [StartupItem] {
        async let userAgents = scanLaunchAgents(at: userAgentsURL, source: .userLaunchAgent)
        async let systemAgents = scanLaunchAgents(at: systemAgentsURL, source: .systemLaunchAgent)
        async let loginItems = scanLoginItems()
        async let heavy = scanHeavyConsumers()

        return await userAgents + systemAgents + loginItems + heavy
    }

    private var userAgentsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    private var systemAgentsURL: URL {
        URL(fileURLWithPath: "/Library/LaunchAgents")
    }

    // MARK: - Launch Agents

    /// Parses every <bundle>.plist in a LaunchAgents directory. Each plist
    /// is a declarative job spec that launchd interprets — we surface the
    /// fields users care about (label, executable, runAtLoad, keepAlive)
    /// and flag broken entries (executable doesn't exist on disk) and
    /// orphans (parent app uninstalled but plist left behind).
    private func scanLaunchAgents(
        at directory: URL,
        source: StartupItem.StartupItemSource
    ) async -> [StartupItem] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }

        var items: [StartupItem] = []
        for entry in entries where entry.hasSuffix(".plist") && !entry.hasPrefix(".") {
            let plistURL = directory.appendingPathComponent(entry)
            if let item = parseAgent(plistURL: plistURL, source: source) {
                items.append(item)
            }
        }
        return items
    }

    private func parseAgent(
        plistURL: URL,
        source: StartupItem.StartupItemSource
    ) -> StartupItem? {
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }

        let label = (plist["Label"] as? String) ?? plistURL.deletingPathExtension().lastPathComponent

        // Apple-owned agents are off-limits — disabling them breaks system
        // services (Spotlight, Time Machine, audio, etc.). Hide them so the
        // user can't accidentally toss one.
        if label.hasPrefix("com.apple.") { return nil }

        // ProgramArguments[0] is the executable; standalone Program is older
        // syntax for the same thing.
        let programArgs = plist["ProgramArguments"] as? [String]
        let standaloneProgram = plist["Program"] as? String
        let exePath = programArgs?.first ?? standaloneProgram
        let exeURL = exePath.map { URL(fileURLWithPath: $0) }

        let runAtLoad = (plist["RunAtLoad"] as? Bool) ?? false
        let keepAlive = parseKeepAlive(plist["KeepAlive"])
        let scheduled = plist["StartInterval"] != nil || plist["StartCalendarInterval"] != nil
        let disabled = (plist["Disabled"] as? Bool) ?? false

        let isExeMissing = exeURL.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true

        // Map the agent back to its parent app via two strategies:
        //   1. If the executable lives inside an .app bundle, walk up to find it.
        //   2. Otherwise, see if the label's first two dot-segments match
        //      an installed app's bundle id (best-effort — many third-party
        //      labels don't follow this convention).
        let parentBundleId = inferParentBundleId(label: label, exeURL: exeURL)
        let isParentMissing = parentBundleId.map { !isAppInstalled(bundleId: $0) } ?? false

        let humanName = humanizeLabel(label)
        let type: StartupItem.StartupItemType = scheduled ? .scheduledTask : .backgroundAgent

        return StartupItem(
            id: "agent::\(source.rawValue)::\(label)",
            name: humanName,
            type: type,
            source: source,
            executablePath: exeURL,
            parentAppBundleId: parentBundleId,
            icon: iconForExecutable(exeURL),
            isEnabled: !disabled,
            isExecutableMissing: isExeMissing,
            isParentAppMissing: isParentMissing,
            keepAlive: keepAlive,
            runAtLoad: runAtLoad,
            requiresAdmin: source == .systemLaunchAgent,
            plistURL: plistURL,
            cpuPercent: nil,
            memoryMB: nil
        )
    }

    /// KeepAlive can be `true`, `false`, or a dictionary of conditions
    /// (SuccessfulExit, NetworkState, etc.). Treat any dictionary form as
    /// "yes, restarts under some condition" since the nuance doesn't change
    /// what the user can do about it.
    private func parseKeepAlive(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if value is [String: Any] { return true }
        return false
    }

    // MARK: - Parent app inference

    private func inferParentBundleId(label: String, exeURL: URL?) -> String? {
        // Walk up from the executable to the enclosing .app bundle.
        if let exeURL {
            var dir = exeURL.deletingLastPathComponent()
            while dir.path != "/" {
                if dir.pathExtension == "app" {
                    let infoPlist = dir.appendingPathComponent("Contents/Info.plist")
                    if let data = try? Data(contentsOf: infoPlist),
                       let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                       let bundleId = plist["CFBundleIdentifier"] as? String {
                        return bundleId
                    }
                    return nil
                }
                dir = dir.deletingLastPathComponent()
            }
        }

        // Fallback: try the label's first two dot-segments as a bundle id.
        // e.g. "com.spotify.webhelper" → "com.spotify.client" — too speculative,
        // skip it. We'll rely on the executable walk above instead.
        _ = label
        return nil
    }

    private func isAppInstalled(bundleId: String) -> Bool {
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil
    }

    private func iconForExecutable(_ url: URL?) -> NSImage? {
        guard let url else { return nil }
        // Walk up to the .app bundle if there is one — bundle icons look
        // much nicer than the generic Unix executable icon.
        var dir = url
        while dir.path != "/" {
            if dir.pathExtension == "app" {
                return NSWorkspace.shared.icon(forFile: dir.path)
            }
            dir = dir.deletingLastPathComponent()
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Turn "com.spotify.webhelper" into "Spotify Webhelper".
    private func humanizeLabel(_ label: String) -> String {
        let parts = label.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return label }
        let tail = parts.dropFirst(parts.count >= 3 ? 2 : 1)
        let pretty = tail.map { word -> String in
            word.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
        }.joined(separator: " ")
        return pretty.isEmpty ? label : pretty
    }

    // MARK: - Login Items (SMAppService)

    /// SMAppService can only enumerate items the *current app* registered.
    /// For TidyMac that's nothing today, so this returns an empty list.
    /// Listing arbitrary user login items requires reading the protected
    /// `backgrounditems.btm` archive — even with Full Disk Access that file
    /// is a binary keyed archive that's brittle to parse. Apps Spotify/
    /// Dropbox/etc. that auto-launch typically install a Launch Agent
    /// anyway, so they show up under that category instead.
    private func scanLoginItems() async -> [StartupItem] {
        if #available(macOS 13.0, *) {
            // Status check the main app — only meaningful if we've registered.
            let status = SMAppService.mainApp.status
            guard status == .enabled || status == .requiresApproval else { return [] }
            let displayName = Bundle.main.infoDictionary?["CFBundleName"] as? String
                ?? "TidyMac"
            return [StartupItem(
                id: "loginitem::\(Bundle.main.bundleIdentifier ?? "main")",
                name: displayName,
                type: .loginItem,
                source: .loginItemSMAppService,
                executablePath: Bundle.main.executableURL,
                parentAppBundleId: Bundle.main.bundleIdentifier,
                icon: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath),
                isEnabled: status == .enabled,
                isExecutableMissing: false,
                isParentAppMissing: false,
                keepAlive: false,
                runAtLoad: true,
                requiresAdmin: false,
                plistURL: nil,
                cpuPercent: nil,
                memoryMB: nil
            )]
        }
        return []
    }

    // MARK: - Heavy Consumers

    /// Live snapshot via `ps -axo pid,%cpu,%mem,rss,comm`. Returns the top
    /// 10 by combined (CPU + memory) load — pure CPU sort puts kernel_task
    /// at the top forever; pure memory sort buries fast-but-spiky offenders.
    private func scanHeavyConsumers() async -> [StartupItem] {
        guard let output = runPS() else { return [] }
        let lines = output.split(separator: "\n").dropFirst() // drop header

        struct Row { let pid: Int; let cpu: Double; let mem: Double; let rss: Double; let comm: String }
        var rows: [Row] = []

        for raw in lines {
            // PID %CPU %MEM   RSS COMM
            let parts = raw.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 5,
                  let pid = Int(parts[0]),
                  let cpu = Double(parts[1]),
                  let mem = Double(parts[2]),
                  let rss = Double(parts[3])
            else { continue }
            let comm = parts.dropFirst(4).joined(separator: " ")
            rows.append(Row(pid: pid, cpu: cpu, mem: mem, rss: rss, comm: comm))
        }

        let top = rows
            .sorted { ($0.cpu + $0.mem) > ($1.cpu + $1.mem) }
            .prefix(10)

        return top.map { row in
            let exeURL = URL(fileURLWithPath: row.comm)
            let displayName = exeURL.lastPathComponent
            // RSS is in KB on Darwin's ps; convert to MB.
            let memMB = row.rss / 1024
            return StartupItem(
                id: "process::\(row.pid)",
                name: displayName,
                type: .heavyConsumer,
                source: .runningProcess,
                executablePath: exeURL,
                parentAppBundleId: nil,
                icon: iconForExecutable(exeURL),
                isEnabled: true,
                isExecutableMissing: false,
                isParentAppMissing: false,
                keepAlive: false,
                runAtLoad: false,
                requiresAdmin: false,
                plistURL: nil,
                cpuPercent: row.cpu,
                memoryMB: memMB
            )
        }
    }

    private func runPS() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid,%cpu,%mem,rss,comm"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        // Drain the pipe BEFORE waiting for exit. ps on a busy Mac produces
        // more than the pipe's ~64 KB buffer, so the child blocks writing
        // while we wait for it to terminate — classic deadlock. readData­
        // ToEndOfFile() returns when the child closes its stdout (on exit),
        // so the subsequent waitUntilExit returns immediately.
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
