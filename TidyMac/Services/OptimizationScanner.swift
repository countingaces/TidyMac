import Foundation
import AppKit
import Darwin
import ServiceManagement

/// Resolves CGSGetIsProcessUnresponsive at runtime via dlsym so we don't
/// link against private symbols at build time. Returns nil on macOS
/// versions where Apple has renamed or removed the SPI — in that case
/// we just report no hung apps rather than crashing or false-positive-ing.
private enum HungProcessSPI {
    typealias Fn = @convention(c) (pid_t) -> Int32

    static let detect: Fn? = {
        let frameworks = [
            "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        ]
        for path in frameworks {
            guard let handle = dlopen(path, RTLD_LAZY) else { continue }
            if let raw = dlsym(handle, "CGSGetIsProcessUnresponsive") {
                return unsafeBitCast(raw, to: Fn.self)
            }
        }
        return nil
    }()
}

/// Inspects everything macOS auto-starts: Launch Agents (user + system),
/// Login Items registered via SMAppService, and a live snapshot of the
/// heaviest CPU/memory consumers right now.
///
/// Read-only. Mutations (enable/disable/remove) live on OptimizationViewModel.
struct OptimizationScanner: Sendable {

    func scan() async -> [StartupItem] {
        async let userAgents = scanLaunchAgents(at: userAgentsURL, source: .userLaunchAgent)
        async let systemAgents = scanLaunchAgents(at: systemAgentsURL, source: .systemLaunchAgent)
        async let systemDaemons = scanLaunchAgents(at: systemDaemonsURL, source: .systemLaunchDaemon)
        async let loginItems = scanLoginItems()
        async let hung = scanHungApps()

        return await userAgents + systemAgents + systemDaemons + loginItems + hung
    }

    private var userAgentsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    private var systemAgentsURL: URL {
        URL(fileURLWithPath: "/Library/LaunchAgents")
    }

    /// /Library/LaunchDaemons holds root-owned daemons started before login —
    /// Docker's vmnetd, zoom's daemon, iLok licenseDaemon, etc. CleanMyMac
    /// surfaces these alongside agents under one tab; do the same. We never
    /// touch /System/Library/LaunchDaemons (Apple-only, all filtered).
    private var systemDaemonsURL: URL {
        URL(fileURLWithPath: "/Library/LaunchDaemons")
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

        // Walk up from the executable to its enclosing .app bundle, if any.
        // Read that bundle's CFBundleName for the human name and CFBundle-
        // Identifier for parent-installed checks. Falls back to the label-
        // humanizer when the executable isn't inside an .app at all (e.g.
        // /usr/local/bin helpers from Homebrew installs).
        let parentInfo = parentAppInfo(for: exeURL)
        let isParentMissing = parentInfo?.bundleId.map { !isAppInstalled(bundleId: $0) } ?? false

        let humanName = parentInfo?.bundleName ?? humanizeLabel(label)
        let type: StartupItem.StartupItemType = scheduled ? .scheduledTask : .backgroundAgent

        return StartupItem(
            id: "agent::\(source.rawValue)::\(label)",
            name: humanName,
            type: type,
            source: source,
            executablePath: exeURL,
            parentAppBundleId: parentInfo?.bundleId,
            icon: iconForExecutable(exeURL),
            isEnabled: !disabled,
            isExecutableMissing: isExeMissing,
            isParentAppMissing: isParentMissing,
            keepAlive: keepAlive,
            runAtLoad: runAtLoad,
            requiresAdmin: source == .systemLaunchAgent || source == .systemLaunchDaemon,
            plistURL: plistURL,
            processIdentifier: nil
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

    /// Resolves the parent .app bundle for an agent's executable, returning
    /// the bundle's display name + identifier. Walking up the path is more
    /// reliable than guessing from the label (Grammarly's labels start with
    /// "com.grammarly.ProjectLlama" — humanizing that gives "Projectllama
    /// Shepherd" instead of "Grammarly Update Service").
    private struct ParentAppInfo {
        let bundleName: String?
        let bundleId: String?
    }

    private func parentAppInfo(for exeURL: URL?) -> ParentAppInfo? {
        guard let exeURL else { return nil }
        var dir = exeURL.deletingLastPathComponent()
        while dir.path != "/" {
            if dir.pathExtension == "app" {
                let infoPlist = dir.appendingPathComponent("Contents/Info.plist")
                guard let data = try? Data(contentsOf: infoPlist),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                else { return nil }
                let bundleName = (plist["CFBundleDisplayName"] as? String)
                    ?? (plist["CFBundleName"] as? String)
                    ?? dir.deletingPathExtension().lastPathComponent
                let bundleId = plist["CFBundleIdentifier"] as? String
                return ParentAppInfo(bundleName: bundleName, bundleId: bundleId)
            }
            dir = dir.deletingLastPathComponent()
        }
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
                processIdentifier: nil
            )]
        }
        return []
    }

    // MARK: - Hung Applications

    /// Walks NSWorkspace's running applications and asks the WindowServer
    /// (via private CGS SPI) which ones have stopped pumping events. Only
    /// considers .regular GUI apps owned by the current user — system
    /// daemons and other users' processes aren't ours to kill.
    private func scanHungApps() async -> [StartupItem] {
        guard let detect = HungProcessSPI.detect else { return [] }

        let me = getuid()
        let candidates = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular &&
            app.processIdentifier > 0 &&
            !app.isTerminated &&
            ownerUID(of: app.processIdentifier) == me
        }

        return candidates.compactMap { app -> StartupItem? in
            guard detect(app.processIdentifier) != 0 else { return nil }
            let bundleURL = app.bundleURL
            let displayName = app.localizedName ?? bundleURL?.deletingPathExtension().lastPathComponent ?? "Unknown"
            return StartupItem(
                id: "hung::\(app.processIdentifier)",
                name: displayName,
                type: .hungApp,
                source: .runningApp,
                executablePath: app.executableURL ?? bundleURL,
                parentAppBundleId: app.bundleIdentifier,
                icon: app.icon,
                isEnabled: false,
                isExecutableMissing: false,
                isParentAppMissing: false,
                keepAlive: false,
                runAtLoad: false,
                requiresAdmin: false,
                plistURL: nil,
                processIdentifier: app.processIdentifier
            )
        }
    }

    /// proc_pidinfo PROC_PIDTBSDINFO gives us the BSD-level process info
    /// including the real UID. Returns -1 if the call fails (process gone,
    /// permissions, etc.) so the caller's "is mine?" check just rejects it.
    private func ownerUID(of pid: pid_t) -> uid_t {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size))
        guard result == Int32(size) else { return uid_t.max }
        return info.pbi_uid
    }
}
