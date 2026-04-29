import Foundation
import AppKit

struct SystemJunkScanner: Sendable {
    struct Progress: Sendable {
        let currentActivity: String
        let itemsFound: Int
        let sizeFound: Int64
    }

    func scan(
        onProgress: @Sendable @escaping (Progress) -> Void
    ) async throws -> [ScanCategory<JunkItem>] {
        let context = await Self.buildContext()

        var results: [ScanCategory<JunkItem>] = []
        var totalItems = 0
        var totalSize: Int64 = 0

        let stages: [(activity: String, work: () async throws -> ScanCategory<JunkItem>)] = [
            ("Scanning user caches…",        { try await scanUserCaches(context: context) }),
            ("Scanning system caches…",      { try await scanSystemCaches() }),
            ("Scanning system logs…",        { try await scanSystemLogs() }),
            ("Scanning user logs…",          { try await scanUserLogs() }),
            ("Reviewing downloads…",         { try await scanDownloads() }),
            ("Scanning Xcode artifacts…",    { try await scanXcodeJunk() }),
            ("Scanning old updates…",        { try await scanOldUpdates() }),
            ("Looking for broken preferences…", { try await scanBrokenPreferences(context: context) }),
            ("Scanning language files…",     { try await scanLanguageFiles(context: context) }),
            ("Scanning universal binaries…", { try await scanUniversalBinaries() }),
            ("Scanning iOS backups…",        { try await scanIOSBackups() })
        ]

        for stage in stages {
            try Task.checkCancellation()
            onProgress(Progress(
                currentActivity: stage.activity,
                itemsFound: totalItems,
                sizeFound: totalSize
            ))

            let category = try await stage.work()
            if !category.items.isEmpty {
                totalItems += category.itemCount
                totalSize += category.totalSize
            }
            results.append(category)
        }

        onProgress(Progress(
            currentActivity: "Done",
            itemsFound: totalItems,
            sizeFound: totalSize
        ))

        return results.filter { !$0.items.isEmpty }
    }

    // MARK: - Pre-scan context

    private struct Context: Sendable {
        let runningAppBundleIds: Set<String>
        let installedAppBundleIds: Set<String>
        let preferredLanguageCodes: Set<String>
    }

    private static func buildContext() async -> Context {
        let runningIds = Set(
            NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        )
        let installedIds = collectInstalledAppBundleIds()
        let prefLangs = collectPreferredLanguageCodes()
        return Context(
            runningAppBundleIds: runningIds,
            installedAppBundleIds: installedIds,
            preferredLanguageCodes: prefLangs
        )
    }

    private static func collectInstalledAppBundleIds() -> Set<String> {
        var result: Set<String> = []
        let appLocations = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Applications", isDirectory: true)
        ]
        let fm = FileManager.default
        for url in appLocations {
            guard let entries = try? fm.contentsOfDirectory(atPath: url.path) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let appURL = url.appendingPathComponent(entry, isDirectory: true)
                let infoPlist = appURL.appendingPathComponent("Contents/Info.plist")
                if let dict = NSDictionary(contentsOf: infoPlist) as? [String: Any],
                   let bundleId = dict["CFBundleIdentifier"] as? String {
                    result.insert(bundleId)
                }
            }
        }
        return result
    }

    private static func collectPreferredLanguageCodes() -> Set<String> {
        // Always keep English + the resource fallback ("Base"), plus any of the
        // user's preferred languages.
        var codes: Set<String> = ["en", "Base", "en_US", "en_GB"]
        for langId in Locale.preferredLanguages {
            let parts = langId.split(separator: "-")
            if let primary = parts.first {
                codes.insert(String(primary))
                if parts.count > 1 {
                    codes.insert(langId.replacingOccurrences(of: "-", with: "_"))
                }
            }
        }
        return codes
    }

    // MARK: - 1. User Cache Files

    private func scanUserCaches(context: Context) async throws -> ScanCategory<JunkItem> {
        try Task.checkCancellation()
        let cachesURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches", isDirectory: true)

        var items: [JunkItem] = []
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: cachesURL.path) {
            for entry in entries {
                try Task.checkCancellation()
                if entry.hasPrefix(".") { continue }

                // Cache subdirs are typically named by bundle id
                if context.runningAppBundleIds.contains(entry) { continue }

                let entryURL = cachesURL.appendingPathComponent(entry, isDirectory: true)
                let size = bulkDirectorySize(at: entryURL)
                if size <= 0 { continue }

                items.append(JunkItem(
                    name: friendlyCacheName(for: entry),
                    path: entryURL,
                    size: size,
                    safetyLevel: .safe,
                    categoryId: "user-caches",
                    lastModified: lastModified(at: entryURL),
                    appBundleId: entry.contains(".") ? entry : nil
                ))
            }
        }

        return makeCategory(
            id: "user-caches",
            title: "User Cache Files",
            description: "Cached data created by apps you've used. Apps will recreate what they need.",
            icon: "internaldrive.badge.timemachine",
            items: items.sorted { $0.size > $1.size }
        )
    }

    // MARK: - 2. System Cache Files

    private func scanSystemCaches() async throws -> ScanCategory<JunkItem> {
        try Task.checkCancellation()
        let url = URL(fileURLWithPath: "/Library/Caches")
        var items: [JunkItem] = []

        if let entries = try? FileManager.default.contentsOfDirectory(atPath: url.path) {
            for entry in entries {
                try Task.checkCancellation()
                if entry.hasPrefix(".") { continue }

                let entryURL = url.appendingPathComponent(entry, isDirectory: true)
                let size = bulkDirectorySize(at: entryURL)
                if size <= 0 { continue }

                items.append(JunkItem(
                    name: friendlyCacheName(for: entry),
                    path: entryURL,
                    size: size,
                    safetyLevel: .safe,
                    categoryId: "system-caches",
                    lastModified: lastModified(at: entryURL),
                    appBundleId: entry.contains(".") ? entry : nil
                ))
            }
        }

        return makeCategory(
            id: "system-caches",
            title: "System Cache Files",
            description: "Caches written by macOS system services. Inaccessible items are skipped.",
            icon: "gear.circle.fill",
            items: items.sorted { $0.size > $1.size }
        )
    }

    // MARK: - 3. System Log Files

    private func scanSystemLogs() async throws -> ScanCategory<JunkItem> {
        let roots = [
            URL(fileURLWithPath: "/var/log"),
            URL(fileURLWithPath: "/Library/Logs")
        ]
        let items = try await scanLogFiles(in: roots, categoryId: "system-logs")
        return makeCategory(
            id: "system-logs",
            title: "System Log Files",
            description: "macOS logs older than 7 days. Recent logs are kept for debugging.",
            icon: "doc.text.fill",
            items: items.sorted { $0.size > $1.size }
        )
    }

    // MARK: - 4. User Log Files

    private func scanUserLogs() async throws -> ScanCategory<JunkItem> {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs", isDirectory: true)
        let items = try await scanLogFiles(in: [url], categoryId: "user-logs")
        return makeCategory(
            id: "user-logs",
            title: "User Log Files",
            description: "App logs in your home folder older than 7 days.",
            icon: "doc.text",
            items: items.sorted { $0.size > $1.size }
        )
    }

    private func scanLogFiles(
        in roots: [URL],
        categoryId: String
    ) async throws -> [JunkItem] {
        let extensions: Set<String> = ["log", "crash", "diag", "ips"]
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)

        var items: [JunkItem] = []
        for root in roots {
            try Task.checkCancellation()
            collectMatchingFiles(
                at: root,
                extensions: extensions,
                olderThan: cutoff
            ) { url, size, modDate in
                items.append(JunkItem(
                    name: url.lastPathComponent,
                    path: url,
                    size: size,
                    safetyLevel: .safe,
                    categoryId: categoryId,
                    lastModified: modDate
                ))
            }
        }
        return items
    }

    // MARK: - 5. Downloads

    private func scanDownloads() async throws -> ScanCategory<JunkItem> {
        try Task.checkCancellation()
        let downloadsURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Downloads", isDirectory: true)
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        let installerExts: Set<String> = ["dmg", "pkg", "zip", "tar", "gz", "tgz", "bz2", "iso"]

        var items: [JunkItem] = []
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: downloadsURL.path) {
            for entry in entries {
                try Task.checkCancellation()
                if entry.hasPrefix(".") { continue }

                let entryURL = downloadsURL.appendingPathComponent(entry)
                let values = try? entryURL.resourceValues(forKeys: [
                    .isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey,
                    .contentModificationDateKey, .contentAccessDateKey, .isSymbolicLinkKey
                ])
                if values?.isSymbolicLink == true { continue }

                let modDate = values?.contentModificationDate
                let accessDate = values?.contentAccessDate
                // Prefer modification date — access dates get touched by
                // Spotlight/Quick Look/Finder previews, hiding genuinely stale
                // files behind a fresh atime. Fall back to access if mod is
                // missing.
                let dateToCheck = modDate ?? accessDate ?? Date()

                let ext = entryURL.pathExtension.lowercased()
                let isInstaller = installerExts.contains(ext)
                let isOld = dateToCheck < cutoff

                guard isInstaller || isOld else { continue }

                let size: Int64
                if values?.isDirectory == true {
                    size = bulkDirectorySize(at: entryURL)
                } else {
                    size = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
                }
                if size <= 0 { continue }

                items.append(JunkItem(
                    name: entry,
                    path: entryURL,
                    size: size,
                    safetyLevel: .cautious,
                    categoryId: "downloads",
                    lastModified: modDate
                ))
            }
        }

        return makeCategory(
            id: "downloads",
            title: "Old Downloads",
            description: "Installers and files in Downloads you may not need anymore.",
            icon: "arrow.down.circle.fill",
            items: items.sorted { $0.size > $1.size },
            isSelected: false  // never auto-select
        )
    }

    // MARK: - 6. Xcode Junk

    private func scanXcodeJunk() async throws -> ScanCategory<JunkItem> {
        guard FileManager.default.fileExists(atPath: "/Applications/Xcode.app") else {
            return makeCategory(
                id: "xcode",
                title: "Xcode Junk",
                description: "Build artifacts, archives, simulators, and device support files.",
                icon: "hammer.fill",
                items: []
            )
        }

        let home = URL(fileURLWithPath: NSHomeDirectory())
        // User-scoped Xcode artifacts
        let userGroups: [(label: String, url: URL)] = [
            ("Derived Data",       home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)),
            ("Archive",            home.appendingPathComponent("Library/Developer/Xcode/Archives", isDirectory: true)),
            ("iOS Device Support", home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport", isDirectory: true)),
            ("Simulator Devices",  home.appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true))
        ]
        // System-scoped simulator runtimes — typically the largest portion of
        // Xcode disk usage. Prior versions only checked the user-scoped paths
        // and badly under-reported.
        let systemGroups: [(label: String, url: URL)] = [
            ("Simulator Runtimes", URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Volumes")),
            ("Simulator Cryptex",  URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Cryptex")),
            ("Simulator Images",   URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Images")),
            ("Simulator Cache",    URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Caches"))
        ]

        var items: [JunkItem] = []
        for group in userGroups + systemGroups {
            try Task.checkCancellation()
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: group.url.path) else { continue }

            for entry in entries {
                try Task.checkCancellation()
                if entry.hasPrefix(".") { continue }
                let entryURL = group.url.appendingPathComponent(entry, isDirectory: true)
                let size = bulkDirectorySize(at: entryURL)
                if size <= 0 { continue }
                items.append(JunkItem(
                    name: "\(group.label) — \(entry)",
                    path: entryURL,
                    size: size,
                    safetyLevel: .safe,
                    categoryId: "xcode",
                    lastModified: lastModified(at: entryURL)
                ))
            }
        }

        return makeCategory(
            id: "xcode",
            title: "Xcode Junk",
            description: "DerivedData, archives, simulators, and device support files.",
            icon: "hammer.fill",
            items: items.sorted { $0.size > $1.size }
        )
    }

    // MARK: - Old Updates (new in this revision)

    private func scanOldUpdates() async throws -> ScanCategory<JunkItem> {
        try Task.checkCancellation()

        let home = URL(fileURLWithPath: NSHomeDirectory())
        let groups: [(label: String, url: URL)] = [
            ("System Update", URL(fileURLWithPath: "/Library/Updates")),
            ("Software Update Cache", home.appendingPathComponent("Library/Caches/com.apple.SoftwareUpdate", isDirectory: true)),
            ("Software Update Support", home.appendingPathComponent("Library/Application Support/com.apple.SoftwareUpdate", isDirectory: true))
        ]

        var items: [JunkItem] = []
        for group in groups {
            try Task.checkCancellation()
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: group.url.path) else { continue }

            for entry in entries {
                try Task.checkCancellation()
                if entry.hasPrefix(".") { continue }
                let entryURL = group.url.appendingPathComponent(entry, isDirectory: true)
                let size = bulkDirectorySize(at: entryURL)
                if size <= 0 { continue }
                items.append(JunkItem(
                    name: "\(group.label) — \(entry)",
                    path: entryURL,
                    size: size,
                    safetyLevel: .safe,
                    categoryId: "old-updates",
                    lastModified: lastModified(at: entryURL)
                ))
            }
        }

        return makeCategory(
            id: "old-updates",
            title: "Old Updates",
            description: "Downloaded macOS installers and software-update caches no longer needed.",
            icon: "arrow.down.app.fill",
            items: items.sorted { $0.size > $1.size }
        )
    }

    // MARK: - 7. Broken Preferences

    private func scanBrokenPreferences(context: Context) async throws -> ScanCategory<JunkItem> {
        try Task.checkCancellation()
        let prefsURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences", isDirectory: true)
        var items: [JunkItem] = []

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: prefsURL.path) else {
            return makeCategory(
                id: "broken-prefs",
                title: "Broken Preferences",
                description: "Preferences for apps that are no longer installed.",
                icon: "questionmark.folder.fill",
                items: []
            )
        }

        for entry in entries {
            try Task.checkCancellation()
            guard entry.hasSuffix(".plist") else { continue }
            let bundleId = String(entry.dropLast(".plist".count))

            // Skip Apple system prefs — they're managed by macOS even if no /Applications app exists
            if bundleId.hasPrefix("com.apple.") { continue }
            if context.installedAppBundleIds.contains(bundleId) { continue }

            let entryURL = prefsURL.appendingPathComponent(entry)
            guard let values = try? entryURL.resourceValues(forKeys: [
                .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey
            ]) else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            if size <= 0 { continue }

            items.append(JunkItem(
                name: entry,
                path: entryURL,
                size: size,
                safetyLevel: .cautious,
                categoryId: "broken-prefs",
                lastModified: values.contentModificationDate,
                appBundleId: bundleId
            ))
        }

        return makeCategory(
            id: "broken-prefs",
            title: "Broken Preferences",
            description: "Preference files for apps that are no longer installed.",
            icon: "questionmark.folder.fill",
            items: items.sorted { $0.size > $1.size }
        )
    }

    // MARK: - 8. Language Files

    private func scanLanguageFiles(context: Context) async throws -> ScanCategory<JunkItem> {
        try Task.checkCancellation()
        let appsURL = URL(fileURLWithPath: "/Applications")
        var items: [JunkItem] = []

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: appsURL.path) else {
            return makeCategory(
                id: "languages",
                title: "Language Files",
                description: "Localizations for languages you don't use.",
                icon: "globe",
                items: []
            )
        }

        for entry in entries where entry.hasSuffix(".app") {
            try Task.checkCancellation()
            let appURL = appsURL.appendingPathComponent(entry, isDirectory: true)
            let resourcesURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)

            guard let resourceEntries = try? FileManager.default.contentsOfDirectory(atPath: resourcesURL.path) else { continue }

            var totalSize: Int64 = 0
            for resourceEntry in resourceEntries where resourceEntry.hasSuffix(".lproj") {
                let langCode = String(resourceEntry.dropLast(".lproj".count))
                if context.preferredLanguageCodes.contains(langCode) { continue }
                let lprojURL = resourcesURL.appendingPathComponent(resourceEntry, isDirectory: true)
                totalSize += bulkDirectorySize(at: lprojURL)
            }

            // Only flag apps with meaningful removable lprojs (>1 MB)
            if totalSize > 1_048_576 {
                let displayName = entry.hasSuffix(".app")
                    ? String(entry.dropLast(".app".count))
                    : entry
                items.append(JunkItem(
                    name: displayName,
                    path: resourcesURL,
                    size: totalSize,
                    safetyLevel: .safe,
                    categoryId: "languages",
                    lastModified: nil
                ))
            }
        }

        return makeCategory(
            id: "languages",
            title: "Language Files",
            description: "Localization files inside apps for languages you don't use.",
            icon: "globe",
            items: items.sorted { $0.size > $1.size }
        )
    }

    // MARK: - 9. Universal Binaries

    private func scanUniversalBinaries() async throws -> ScanCategory<JunkItem> {
        try Task.checkCancellation()

        #if arch(arm64)
        let unwantedArch = "x86_64"
        #else
        let unwantedArch = "arm64"
        #endif

        let lipoPath = "/usr/bin/lipo"
        guard FileManager.default.isExecutableFile(atPath: lipoPath) else {
            return makeCategory(
                id: "universal",
                title: "Universal Binaries",
                description: "Unused architecture slices in apps. Removing them may invalidate code signatures.",
                icon: "cpu",
                items: []
            )
        }

        let home = URL(fileURLWithPath: NSHomeDirectory())
        // Skip /System/Applications: those are sealed/read-only and can't be
        // stripped anyway.
        let appLocations: [URL] = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            home.appendingPathComponent("Applications", isDirectory: true)
        ]
        var items: [JunkItem] = []

        for appsURL in appLocations {
            try Task.checkCancellation()
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: appsURL.path) else { continue }

            for entry in entries where entry.hasSuffix(".app") {
                try Task.checkCancellation()
                let appURL = appsURL.appendingPathComponent(entry, isDirectory: true)
                let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")

                guard let info = NSDictionary(contentsOf: infoPlistURL) as? [String: Any],
                      let exeName = info["CFBundleExecutable"] as? String
                else { continue }

                let exeURL = appURL.appendingPathComponent("Contents/MacOS").appendingPathComponent(exeName)
                guard FileManager.default.fileExists(atPath: exeURL.path) else { continue }

                let unwantedSize = sliceSize(of: exeURL.path, for: unwantedArch, lipoPath: lipoPath)
                guard unwantedSize > 1_048_576 else { continue }

                let displayName = entry.hasSuffix(".app")
                    ? String(entry.dropLast(".app".count))
                    : entry
                items.append(JunkItem(
                    name: "\(displayName) (\(unwantedArch) slice)",
                    path: exeURL,
                    size: unwantedSize,
                    safetyLevel: .cautious,
                    categoryId: "universal"
                ))
            }
        }

        return makeCategory(
            id: "universal",
            title: "Universal Binaries",
            description: "Unused architecture slices in apps. Stripping them can invalidate code signatures.",
            icon: "cpu",
            items: items.sorted { $0.size > $1.size }
        )
    }

    private func sliceSize(of binaryPath: String, for arch: String, lipoPath: String) -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lipoPath)
        process.arguments = ["-detailed_info", binaryPath]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return 0
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return 0 }

        // Parse: "architecture <arch>" begins a section, "size <bytes>" gives slice size.
        var inSection = false
        for rawLine in output.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("architecture ") {
                inSection = line.split(separator: " ").last.map(String.init) == arch
            } else if inSection, line.hasPrefix("size ") {
                let parts = line.split(separator: " ")
                if parts.count >= 2, let bytes = Int64(parts[1]) {
                    return bytes
                }
            }
        }
        return 0
    }

    // MARK: - 10. Old iOS Backups

    private func scanIOSBackups() async throws -> ScanCategory<JunkItem> {
        try Task.checkCancellation()
        let backupsURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/MobileSync/Backup", isDirectory: true)
        let cutoff = Date().addingTimeInterval(-180 * 24 * 60 * 60) // ~6 months

        var items: [JunkItem] = []
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: backupsURL.path) else {
            return makeCategory(
                id: "ios-backups",
                title: "Old iOS Backups",
                description: "Old iPhone/iPad backups stored on your Mac.",
                icon: "iphone.gen2",
                items: []
            )
        }

        for entry in entries {
            try Task.checkCancellation()
            if entry.hasPrefix(".") { continue }
            let backupURL = backupsURL.appendingPathComponent(entry, isDirectory: true)

            let info = NSDictionary(contentsOf: backupURL.appendingPathComponent("Info.plist")) as? [String: Any]
            let deviceName = (info?["Device Name"] as? String) ?? entry
            let lastBackupDate = (info?["Last Backup Date"] as? Date) ?? lastModified(at: backupURL)

            // Only flag backups older than ~6 months
            if let date = lastBackupDate, date >= cutoff { continue }

            let size = bulkDirectorySize(at: backupURL)
            if size <= 0 { continue }

            items.append(JunkItem(
                name: deviceName,
                path: backupURL,
                size: size,
                safetyLevel: .cautious,
                categoryId: "ios-backups",
                lastModified: lastBackupDate
            ))
        }

        return makeCategory(
            id: "ios-backups",
            title: "Old iOS Backups",
            description: "iPhone/iPad backups older than 6 months.",
            icon: "iphone.gen2",
            items: items.sorted { $0.size > $1.size }
        )
    }

    // MARK: - Helpers

    private func makeCategory(
        id: String,
        title: String,
        description: String,
        icon: String,
        items: [JunkItem],
        isSelected: Bool = true
    ) -> ScanCategory<JunkItem> {
        ScanCategory(
            id: id,
            title: title,
            description: description,
            icon: icon,
            items: items,
            isSelected: isSelected
        )
    }

    private func friendlyCacheName(for raw: String) -> String {
        // "com.spotify.client" -> "Spotify"; otherwise pass through
        guard raw.contains(".") else { return raw }
        let parts = raw.split(separator: ".")
        guard let last = parts.last else { return raw }
        if last.count >= 3 {
            return String(last).prefix(1).capitalized + String(last).dropFirst()
        }
        return raw
    }

    private func bulkDirectorySize(at url: URL) -> Int64 {
        var total: Int64 = 0
        do {
            let entries = try BulkDirectoryReader.enumerate(at: url.path)
            for entry in entries {
                if entry.isSymbolicLink { continue }
                if entry.isDirectory {
                    let childURL = url.appendingPathComponent(entry.name, isDirectory: true)
                    total += bulkDirectorySize(at: childURL)
                } else {
                    total += entry.size
                }
            }
        } catch {
            // Permission denied or non-supporting filesystem — silently skip.
        }
        return total
    }

    private func lastModified(at url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func collectMatchingFiles(
        at root: URL,
        extensions: Set<String>,
        olderThan cutoff: Date,
        emit: (URL, Int64, Date?) -> Void
    ) {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isSymbolicLinkKey,
            .fileSizeKey, .totalFileAllocatedSizeKey,
            .contentModificationDateKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true { continue }

            let ext = url.pathExtension.lowercased()
            guard extensions.contains(ext) else { continue }

            if let modDate = values.contentModificationDate, modDate >= cutoff { continue }

            let size = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            if size <= 0 { continue }

            emit(url, size, values.contentModificationDate)
        }
    }
}
