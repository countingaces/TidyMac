import Foundation
import AppKit

struct AppDiscoveryService: Sendable {

    /// Discover all installed `.app` bundles across the standard locations
    /// and read their metadata (bundle id, version, size, icon, last-used date).
    /// Apps are deduplicated by bundle identifier, since some can appear in
    /// multiple locations (e.g. Homebrew cask + /Applications symlink).
    func discoverApps() async -> [AppInfo] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let scanLocations: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            home.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/Caskroom"),
            URL(fileURLWithPath: "/usr/local/Caskroom")
        ]

        var apps: [AppInfo] = []
        var seen = Set<String>()

        for location in scanLocations {
            let found = await scan(location: location)
            for app in found where seen.insert(app.id).inserted {
                apps.append(app)
            }
        }

        return apps
    }

    // MARK: - Per-location scan

    private func scan(location: URL) async -> [AppInfo] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: location.path) else {
            return []
        }

        var apps: [AppInfo] = []

        // Homebrew Caskroom layout: /opt/homebrew/Caskroom/<cask>/<version>/<App>.app
        // For non-cask locations, .app bundles live directly under the location.
        let isCaskroom = location.path.hasSuffix("/Caskroom")

        for entry in entries {
            if entry.hasPrefix(".") { continue }

            if isCaskroom {
                // Drill into <cask>/<version>/ to find the .app
                let caskRoot = location.appendingPathComponent(entry, isDirectory: true)
                if let app = findCaskroomApp(in: caskRoot) {
                    apps.append(app)
                }
            } else if entry.hasSuffix(".app") {
                let bundleURL = location.appendingPathComponent(entry, isDirectory: true)
                if let app = readApp(at: bundleURL) {
                    apps.append(app)
                }
            }
        }

        return apps
    }

    private func findCaskroomApp(in caskRoot: URL) -> AppInfo? {
        let fm = FileManager.default
        guard let versionDirs = try? fm.contentsOfDirectory(atPath: caskRoot.path) else { return nil }
        for versionDir in versionDirs where !versionDir.hasPrefix(".") {
            let versionURL = caskRoot.appendingPathComponent(versionDir, isDirectory: true)
            guard let inner = try? fm.contentsOfDirectory(atPath: versionURL.path) else { continue }
            for entry in inner where entry.hasSuffix(".app") {
                let bundleURL = versionURL.appendingPathComponent(entry, isDirectory: true)
                return readApp(at: bundleURL, forcedCategory: .homebrew)
            }
        }
        return nil
    }

    // MARK: - Metadata extraction

    private func readApp(at bundleURL: URL, forcedCategory: AppCategory? = nil) -> AppInfo? {
        let infoPlistURL = bundleURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return nil
        }

        guard let bundleId = plist["CFBundleIdentifier"] as? String, !bundleId.isEmpty else {
            return nil
        }

        let displayName = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent

        let version = (plist["CFBundleShortVersionString"] as? String)
            ?? (plist["CFBundleVersion"] as? String)
            ?? "—"

        let category = forcedCategory ?? Self.classify(bundleId: bundleId, bundleURL: bundleURL)
        let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
        let size = bundleSize(at: bundleURL)
        let lastUsed = lastUsedDate(forBundle: bundleURL)
        let sandboxed = Self.isSandboxed(bundleId: bundleId)

        return AppInfo(
            id: bundleId,
            name: displayName,
            version: version,
            bundlePath: bundleURL,
            bundleSize: size,
            category: category,
            icon: icon,
            lastUsedDate: lastUsed,
            isSandboxed: sandboxed
        )
    }

    private static func classify(bundleId: String, bundleURL: URL) -> AppCategory {
        let path = bundleURL.path
        if path.hasPrefix("/System/Applications") { return .appleBuiltIn }
        if path.contains("/Caskroom/") { return .homebrew }
        if path.hasPrefix("/Applications/Utilities") { return .utility }

        // App Store apps ship with a Mach-O receipt at Contents/_MASReceipt/receipt
        let receiptURL = bundleURL.appendingPathComponent("Contents/_MASReceipt/receipt")
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            return .appStore
        }

        if bundleId.hasPrefix("com.apple.") { return .appleBuiltIn }
        return .thirdParty
    }

    private static func isSandboxed(bundleId: String) -> Bool {
        let containerPath = NSHomeDirectory() + "/Library/Containers/" + bundleId
        return FileManager.default.fileExists(atPath: containerPath)
    }

    // MARK: - Bundle size

    private func bundleSize(at url: URL) -> Int64 {
        var total: Int64 = 0
        do {
            let entries = try BulkDirectoryReader.enumerate(at: url.path)
            for entry in entries {
                if entry.isSymbolicLink { continue }
                if entry.isDirectory {
                    total += bundleSize(at: url.appendingPathComponent(entry.name, isDirectory: true))
                } else {
                    total += entry.size
                }
            }
        } catch {
            // Permission/IO errors — return what we accumulated.
        }
        return total
    }

    // MARK: - Spotlight last-used date

    /// Reads kMDItemLastUsedDate via `mdls`. macOS only updates the file
    /// system atime sporadically, so Spotlight metadata is the most reliable
    /// source. Returns nil if Spotlight has never indexed this app.
    private func lastUsedDate(forBundle url: URL) -> Date? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdls")
        process.arguments = ["-name", "kMDItemLastUsedDate", "-raw", url.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw != "(null)"
        else {
            return nil
        }

        // mdls -raw emits e.g. "2025-12-31 18:42:07 +0000"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: raw)
    }
}
