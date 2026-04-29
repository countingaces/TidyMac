import Foundation
import AppKit

struct RemnantScanner: Sendable {

    /// Search the standard macOS Library locations for files associated with
    /// the given app via its bundle identifier (and, for some locations, its
    /// display name). Returns an array of remnants sorted by descending size.
    func scan(for app: AppInfo) async -> [AppRemnant] {
        // Never flag Apple system app remnants — many of those files are
        // managed by the OS and removing them breaks things.
        if app.id.hasPrefix("com.apple.") {
            return []
        }

        // Don't flag remnants for currently-running applications. The user
        // would have to quit them first; they can re-scan after.
        let runningIds = Set(NSWorkspace.shared.runningApplications
            .compactMap { $0.bundleIdentifier })
        if runningIds.contains(app.id) {
            return []
        }

        let home = URL(fileURLWithPath: NSHomeDirectory())
        var found: [AppRemnant] = []

        let plans: [Plan] = [
            // 1. Application Support — directory entries by bundle id OR app name
            Plan(
                location: home.appendingPathComponent("Library/Application Support", isDirectory: true),
                category: .applicationSupport,
                matcher: directoryNameMatcher
            ),

            // 2. Containers — directory entries by bundle id
            Plan(
                location: home.appendingPathComponent("Library/Containers", isDirectory: true),
                category: .container,
                matcher: bundleIdDirectoryMatcher
            ),

            // 2b. Group Containers — directory entries prefixed with "group."
            Plan(
                location: home.appendingPathComponent("Library/Group Containers", isDirectory: true),
                category: .container,
                matcher: groupContainerMatcher
            ),

            // 3. Caches — directory entries by bundle id OR app name
            Plan(
                location: home.appendingPathComponent("Library/Caches", isDirectory: true),
                category: .cache,
                matcher: directoryNameMatcher
            ),

            // 4. Preferences — <bundleId>.plist files (and rarer <bundleId>/ dirs)
            Plan(
                location: home.appendingPathComponent("Library/Preferences", isDirectory: true),
                category: .preferences,
                matcher: preferencesMatcher
            ),

            // 5. Saved Application State — <bundleId>.savedState/ dirs
            Plan(
                location: home.appendingPathComponent("Library/Saved Application State", isDirectory: true),
                category: .savedState,
                matcher: suffixMatcher(suffix: ".savedState")
            ),

            // 6. Logs — by bundle id OR app name
            Plan(
                location: home.appendingPathComponent("Library/Logs", isDirectory: true),
                category: .logs,
                matcher: directoryNameMatcher
            ),

            // 7. Launch Agents (user) — <bundleId>*.plist
            Plan(
                location: home.appendingPathComponent("Library/LaunchAgents", isDirectory: true),
                category: .launchAgent,
                matcher: launchAgentMatcher
            ),
            // 7b. Launch Agents (system)
            Plan(
                location: URL(fileURLWithPath: "/Library/LaunchAgents"),
                category: .launchAgent,
                matcher: launchAgentMatcher
            ),
            // 7c. Launch Daemons (system)
            Plan(
                location: URL(fileURLWithPath: "/Library/LaunchDaemons"),
                category: .launchAgent,
                matcher: launchAgentMatcher
            ),

            // 9. Cookies — <bundleId>.binarycookies
            Plan(
                location: home.appendingPathComponent("Library/Cookies", isDirectory: true),
                category: .cookies,
                matcher: suffixMatcher(suffix: ".binarycookies")
            ),

            // 10. HTTP Storage — directory entries by bundle id
            Plan(
                location: home.appendingPathComponent("Library/HTTPStorages", isDirectory: true),
                category: .httpStorage,
                matcher: bundleIdDirectoryMatcher
            ),

            // 11. WebKit data — directory entries by bundle id
            Plan(
                location: home.appendingPathComponent("Library/WebKit", isDirectory: true),
                category: .webkitData,
                matcher: bundleIdDirectoryMatcher
            ),

            // 12. Crash reports — <AppName>_*.crash / .ips
            Plan(
                location: home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true),
                category: .crashReports,
                matcher: crashReportMatcher
            )
        ]

        for plan in plans {
            found.append(contentsOf: scan(plan: plan, for: app))
        }

        return found.sorted { $0.size > $1.size }
    }

    // MARK: - Plan execution

    private struct Plan {
        let location: URL
        let category: AppRemnant.RemnantCategory
        let matcher: (String, AppInfo) -> AppRemnant.MatchConfidence?
    }

    private func scan(plan: Plan, for app: AppInfo) -> [AppRemnant] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: plan.location.path) else {
            return []
        }

        var found: [AppRemnant] = []
        for entry in entries {
            if entry.hasPrefix(".") { continue }
            guard let confidence = plan.matcher(entry, app) else { continue }

            let entryURL = plan.location.appendingPathComponent(entry)
            let isDir = (try? entryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let size: Int64
            if isDir {
                size = bulkDirectorySize(at: entryURL)
            } else {
                let attrs = try? entryURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
                size = Int64(attrs?.totalFileAllocatedSize ?? attrs?.fileSize ?? 0)
            }
            if size <= 0 { continue }

            found.append(AppRemnant(
                path: entryURL,
                size: size,
                category: plan.category,
                matchConfidence: confidence,
                description: describe(entry: entry, in: plan.location, category: plan.category)
            ))
        }
        return found
    }

    private func describe(entry: String, in location: URL, category: AppRemnant.RemnantCategory) -> String {
        let homePrefix = NSHomeDirectory() + "/"
        let display = location.path.hasPrefix(homePrefix)
            ? "~/" + String(location.path.dropFirst(homePrefix.count))
            : location.path
        return "\(display)/\(entry)"
    }

    // MARK: - Matchers

    /// Matches an entry whose name is the bundle id, a bundle id prefix, or
    /// the app's display name. Used for Application Support / Caches / Logs.
    private func directoryNameMatcher(_ name: String, app: AppInfo) -> AppRemnant.MatchConfidence? {
        let lower = name.lowercased()
        let bundleId = app.id.lowercased()
        let appName = app.name.lowercased()

        if lower == bundleId { return .exact }
        if lower.hasPrefix(bundleId + ".") { return .prefixMatch }
        if lower == appName { return .nameMatch }
        return nil
    }

    /// Matches an entry that is exactly the bundle id (or a dotted prefix).
    /// Used for Containers / HTTPStorages / WebKit.
    private func bundleIdDirectoryMatcher(_ name: String, app: AppInfo) -> AppRemnant.MatchConfidence? {
        let lower = name.lowercased()
        let bundleId = app.id.lowercased()

        // Skip system-extension-like containers — macOS won't let us trash
        // them via NSWorkspace.recycle even when they're owned by the user.
        // The parent app's own uninstaller (or pluginkit / OSSystemExtension
        // APIs) is the right tool for these.
        if Self.looksLikeSystemExtensionContainer(name) { return nil }

        if lower == bundleId { return .exact }
        if lower.hasPrefix(bundleId + ".") { return .prefixMatch }
        return nil
    }

    /// Detects names like:
    ///   com.foo.app.fileprovider
    ///   com.foo.app.SafariExtension
    ///   com.foo.app.FinderSync
    ///   2BUA8C4S2C.com.1password.browser-helper   (Team ID prefix)
    static func looksLikeSystemExtensionContainer(_ name: String) -> Bool {
        // Team ID prefix: 10 alphanumeric chars followed by a dot.
        if name.count > 11 {
            let prefix = String(name.prefix(10))
            let separator = name[name.index(name.startIndex, offsetBy: 10)]
            if separator == ".", prefix.allSatisfy({ $0.isLetter || $0.isNumber }) {
                return true
            }
        }

        let lower = name.lowercased()
        let suffixes = [
            ".fileprovider",
            ".fpext",                    // alt file-provider suffix (Google Drive)
            ".transferextension",
            ".safariextension",
            ".sendtoextension",
            ".contextmenuextension",
            ".findersync",
            ".finderhelper",
            ".notificationserviceextension",
            ".notification-content-extension",
            ".quicklookextension",
            ".previewextension",
            ".photoextension",
            ".auth-service-extension",
            ".browser-helper",
            ".credentialprovider",
            ".systemextension"
        ]
        return suffixes.contains(where: { lower.hasSuffix($0) })
    }

    /// Matches entries prefixed with "group." for Group Containers.
    private func groupContainerMatcher(_ name: String, app: AppInfo) -> AppRemnant.MatchConfidence? {
        let lower = name.lowercased()
        guard lower.hasPrefix("group.") else { return nil }
        let stem = String(lower.dropFirst("group.".count))
        let bundleId = app.id.lowercased()
        if stem == bundleId { return .exact }
        if stem.hasPrefix(bundleId + ".") { return .prefixMatch }
        return nil
    }

    /// `~/Library/Preferences/<bundleId>.plist` plus rarer `<bundleId>/` dirs.
    private func preferencesMatcher(_ name: String, app: AppInfo) -> AppRemnant.MatchConfidence? {
        let lower = name.lowercased()
        let bundleId = app.id.lowercased()

        if lower.hasSuffix(".plist") {
            let stem = String(lower.dropLast(".plist".count))
            if stem == bundleId { return .exact }
            if stem.hasPrefix(bundleId + ".") { return .prefixMatch }
        } else {
            if lower == bundleId { return .exact }
        }
        return nil
    }

    /// `<bundleId>.plist` for LaunchAgents/LaunchDaemons.
    private func launchAgentMatcher(_ name: String, app: AppInfo) -> AppRemnant.MatchConfidence? {
        guard name.hasSuffix(".plist") else { return nil }
        let stem = String(name.dropLast(".plist".count)).lowercased()
        let bundleId = app.id.lowercased()
        if stem == bundleId { return .exact }
        if stem.hasPrefix(bundleId + ".") { return .prefixMatch }
        return nil
    }

    /// Helper: matches "<bundleId><suffix>" exactly.
    private func suffixMatcher(suffix: String) -> (String, AppInfo) -> AppRemnant.MatchConfidence? {
        return { name, app in
            guard name.hasSuffix(suffix) else { return nil }
            let stem = String(name.dropLast(suffix.count)).lowercased()
            let bundleId = app.id.lowercased()
            if stem == bundleId { return .exact }
            if stem.hasPrefix(bundleId + ".") { return .prefixMatch }
            return nil
        }
    }

    /// Crash reports are filed as `<AppName>_<timestamp>_<host>.crash` (or .ips).
    /// Match by app display name as the prefix before the underscore.
    private func crashReportMatcher(_ name: String, app: AppInfo) -> AppRemnant.MatchConfidence? {
        let isCrash = name.hasSuffix(".crash") || name.hasSuffix(".ips")
        guard isCrash else { return nil }
        let prefix = app.name + "_"
        if name.hasPrefix(prefix) { return .nameMatch }
        return nil
    }

    // MARK: - Helpers

    private func bulkDirectorySize(at url: URL) -> Int64 {
        var total: Int64 = 0
        do {
            let entries = try BulkDirectoryReader.enumerate(at: url.path)
            for entry in entries {
                if entry.isSymbolicLink { continue }
                if entry.isDirectory {
                    total += bulkDirectorySize(at: url.appendingPathComponent(entry.name, isDirectory: true))
                } else {
                    total += entry.size
                }
            }
        } catch {
            // Ignore permission errors; partial size is OK.
        }
        return total
    }
}
