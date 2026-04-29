import Foundation

// MARK: - Protocol

/// One housekeeping operation the user can run on their Mac. Each task
/// pairs a `dryRun()` (preview what will happen + estimated impact) with
/// an `execute()` that does the work. Same shape as Terraform's
/// plan/apply, Docker Compose up, or systemd unit start — preview before
/// commit is the universal sysadmin safety pattern.
protocol MaintenanceTask: Identifiable, Sendable {
    var id: String { get }
    var name: String { get }
    var description: String { get }
    var icon: String { get }
    var estimatedDuration: String { get }
    var requiresAdmin: Bool { get }
    var warning: String? { get }

    func dryRun() async -> MaintenanceTaskPreview
    func execute() async throws -> MaintenanceTaskResult
}

extension MaintenanceTask {
    var warning: String? { nil }
}

struct MaintenanceTaskPreview: Sendable {
    let description: String
    let warnings: [String]
    let estimatedImpact: Impact

    enum Impact: String, Sendable {
        case minimal = "Minimal"
        case moderate = "Moderate"
        case significant = "Significant"
    }
}

struct MaintenanceTaskResult: Sendable {
    let success: Bool
    let summary: String
    let duration: TimeInterval
    let details: String?
}

enum MaintenanceError: LocalizedError {
    case commandFailed(String)
    case authorizationCancelled
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let msg): return msg
        case .authorizationCancelled: return "Authorization was cancelled."
        case .unsupported(let msg): return msg
        }
    }
}

// MARK: - Catalog

enum MaintenanceCatalog {
    /// All tasks available on this Mac. Mail rebuild is conditional on
    /// Mail.app having created its data directory; everything else is
    /// universally applicable.
    static func availableTasks() -> [any MaintenanceTask] {
        var list: [any MaintenanceTask] = [
            FreeUpRAMTask(),
            FreeUpPurgeableSpaceTask(),
            FlushDNSCacheTask(),
            ReindexSpotlightTask(),
            RepairDiskPermissionsTask(),
            ClearFontCachesTask()
        ]
        let mailDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Mail", isDirectory: true)
        if FileManager.default.fileExists(atPath: mailDir.path) {
            list.insert(RebuildMailIndexTask(), at: 5)
        }
        return list
    }
}

// MARK: - Shell helpers

/// Runs a shell command without sudo. Returns combined stdout+stderr.
@discardableResult
func runShell(_ executable: String, _ arguments: [String]) async throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    // Drain pipes BEFORE waitUntilExit. If the command produces more than
    // the ~64 KB pipe buffer, the child blocks writing while we wait for it
    // to finish — classic deadlock.
    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let combined = (String(data: outData, encoding: .utf8) ?? "")
        + (String(data: errData, encoding: .utf8) ?? "")
    if process.terminationStatus != 0 {
        throw MaintenanceError.commandFailed(combined.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return combined
}

/// Runs a shell command with administrator privileges via osascript's
/// `do shell script ... with administrator privileges`. macOS shows the
/// standard system prompt; user enters their password once and the
/// command runs as root.
@discardableResult
func runShellAsAdmin(_ command: String) async throws -> String {
    // Escape backslashes and double-quotes for inclusion in an AppleScript
    // string literal.
    let escaped = command
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    let script = "do shell script \"\(escaped)\" with administrator privileges"

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    // Drain pipes BEFORE waitUntilExit — see runShell for the same fix.
    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let out = String(data: outData, encoding: .utf8) ?? ""
    let err = String(data: errData, encoding: .utf8) ?? ""
    if process.terminationStatus != 0 {
        // -128 is "user cancelled" in AppleScript land.
        if err.contains("-128") {
            throw MaintenanceError.authorizationCancelled
        }
        throw MaintenanceError.commandFailed(err.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return out
}

private func formatBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

// MARK: - 1. Free Up RAM

struct FreeUpRAMTask: MaintenanceTask {
    let id = "free-up-ram"
    let name = "Free Up RAM"
    let description = "Asks the kernel to flush inactive memory pages back to free."
    let icon = "memorychip"
    let estimatedDuration = "A few seconds"
    let requiresAdmin = true
    var warning: String? {
        "macOS automatically manages memory. Freeing RAM is temporary and may briefly slow your Mac as caches are rebuilt."
    }

    func dryRun() async -> MaintenanceTaskPreview {
        let stats = (try? await runShell("/usr/bin/vm_stat", [])) ?? ""
        // vm_stat output uses 4096-byte pages by default but reports the
        // page size in its header.
        let pageSize = parsePageSize(stats) ?? 4096
        let inactivePages = parseStat(stats, key: "Pages inactive:") ?? 0
        let freePages = parseStat(stats, key: "Pages free:") ?? 0
        let inactiveBytes = Int64(inactivePages * pageSize)
        let freeBytes = Int64(freePages * pageSize)
        return MaintenanceTaskPreview(
            description: "About \(formatBytes(inactiveBytes)) of inactive memory could be released. \(formatBytes(freeBytes)) is already free.",
            warnings: ["macOS will reclaim this immediately for caches; the freed bytes are mostly cosmetic."],
            estimatedImpact: .minimal
        )
    }

    func execute() async throws -> MaintenanceTaskResult {
        let start = Date()
        _ = try await runShellAsAdmin("/usr/sbin/purge")
        return MaintenanceTaskResult(
            success: true,
            summary: "Purged inactive memory pages.",
            duration: Date().timeIntervalSince(start),
            details: nil
        )
    }

    private func parsePageSize(_ stats: String) -> Int? {
        // "Mach Virtual Memory Statistics: (page size of 16384 bytes)"
        guard let range = stats.range(of: "page size of ") else { return nil }
        let tail = stats[range.upperBound...]
        let numeric = tail.prefix { $0.isNumber }
        return Int(numeric)
    }

    private func parseStat(_ stats: String, key: String) -> Int? {
        for line in stats.split(separator: "\n") where line.contains(key) {
            let digits = line.filter { $0.isNumber }
            return Int(digits)
        }
        return nil
    }
}

// MARK: - 2. Free Up Purgeable Space

struct FreeUpPurgeableSpaceTask: MaintenanceTask {
    let id = "purge-purgeable"
    let name = "Free Up Purgeable Space"
    let description = "Reclaims disk space APFS has flagged as deletable but hasn't yet released."
    let icon = "internaldrive"
    let estimatedDuration = "A few seconds to a minute"
    let requiresAdmin = false

    func dryRun() async -> MaintenanceTaskPreview {
        let info = (try? await runShell("/usr/sbin/diskutil", ["info", "/"])) ?? ""
        // The "Container Free Space" line includes the purgeable bytes in
        // parentheses on modern macOS — e.g. "5.0 GB (5,000,000,000 Bytes)
        // (Purgeable: 1.2 GB ...)".
        let purgeable = parsePurgeable(info)
        let summary = purgeable.map {
            "About \(formatBytes($0)) is currently purgeable and can be reclaimed."
        } ?? "Couldn't determine current purgeable space — the actual amount will be shown after running."
        return MaintenanceTaskPreview(
            description: summary,
            warnings: [],
            estimatedImpact: purgeable.map { $0 > 1_000_000_000 ? .significant : .moderate } ?? .moderate
        )
    }

    func execute() async throws -> MaintenanceTaskResult {
        let start = Date()
        // diskutil's purge verb takes no extra args. Output looks like
        // "Started APFS operation … Finished APFS operation".
        let output = try await runShell("/usr/sbin/diskutil", ["apfs", "purgePurgeableSpace", "/"])
        return MaintenanceTaskResult(
            success: true,
            summary: "Asked APFS to reclaim purgeable space.",
            duration: Date().timeIntervalSince(start),
            details: output
        )
    }

    private func parsePurgeable(_ info: String) -> Int64? {
        for line in info.split(separator: "\n") where line.contains("Purgeable") {
            // Line looks like: "(Purgeable: 1234567890 Bytes)"
            let scanner = Scanner(string: String(line))
            scanner.charactersToBeSkipped = CharacterSet.alphanumerics.inverted
            if scanner.scanUpToString("Purgeable") != nil {
                _ = scanner.scanString("Purgeable")
                if let bytes = scanner.scanInt64() {
                    return bytes
                }
            }
        }
        return nil
    }
}

// MARK: - 3. Flush DNS Cache

struct FlushDNSCacheTask: MaintenanceTask {
    let id = "flush-dns"
    let name = "Flush DNS Cache"
    let description = "Clears cached domain name lookups so the next visit re-resolves from scratch."
    let icon = "network"
    let estimatedDuration = "A few seconds"
    let requiresAdmin = true

    func dryRun() async -> MaintenanceTaskPreview {
        return MaintenanceTaskPreview(
            description: "Will clear the system DNS cache and restart mDNSResponder.",
            warnings: ["The first lookup of each website after running will be slightly slower as it goes through the full DNS resolution chain."],
            estimatedImpact: .minimal
        )
    }

    func execute() async throws -> MaintenanceTaskResult {
        let start = Date()
        _ = try await runShellAsAdmin("/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder")
        return MaintenanceTaskResult(
            success: true,
            summary: "DNS cache flushed and mDNSResponder restarted.",
            duration: Date().timeIntervalSince(start),
            details: nil
        )
    }
}

// MARK: - 4. Reindex Spotlight

struct ReindexSpotlightTask: MaintenanceTask {
    let id = "reindex-spotlight"
    let name = "Reindex Spotlight"
    let description = "Erases the Spotlight index for the system disk and triggers a full rebuild."
    let icon = "magnifyingglass"
    let estimatedDuration = "10-30 minutes for the rebuild"
    let requiresAdmin = true
    var warning: String? {
        "Search results will be incomplete or empty during the rebuild. Spotlight will reindex in the background."
    }

    func dryRun() async -> MaintenanceTaskPreview {
        return MaintenanceTaskPreview(
            description: "Will erase the Spotlight index at /.Spotlight-V100 and start a full reindex of the boot disk.",
            warnings: [
                "Search results will be incomplete during the rebuild (typically 10-30 minutes).",
                "Battery life and CPU use will be elevated until indexing completes."
            ],
            estimatedImpact: .significant
        )
    }

    func execute() async throws -> MaintenanceTaskResult {
        let start = Date()
        _ = try await runShellAsAdmin("/usr/bin/mdutil -E /")
        return MaintenanceTaskResult(
            success: true,
            summary: "Spotlight index erased. Reindexing has started in the background.",
            duration: Date().timeIntervalSince(start),
            details: nil
        )
    }
}

// MARK: - 5. Repair Disk Permissions

struct RepairDiskPermissionsTask: MaintenanceTask {
    let id = "repair-permissions"
    let name = "Repair Disk Permissions"
    let description = "Resets ownership and ACLs on your home directory back to the defaults."
    let icon = "wrench.and.screwdriver"
    let estimatedDuration = "Several minutes for large home directories"
    let requiresAdmin = true
    var warning: String? {
        "diskutil walks every file in your home folder and can take 5+ minutes on large accounts. Don't quit TidyMac while it runs."
    }

    func dryRun() async -> MaintenanceTaskPreview {
        return MaintenanceTaskPreview(
            description: "Will reset user permissions on your home directory using diskutil.",
            warnings: ["Modern macOS rarely needs this — SIP keeps system files correct. Most useful after a failed app install or migration."],
            estimatedImpact: .moderate
        )
    }

    func execute() async throws -> MaintenanceTaskResult {
        let start = Date()
        let uid = getuid()
        // Discard diskutil's per-file output. On a large home directory it
        // can dump tens of MB of "resetting permissions on …" lines that
        // osascript would otherwise have to buffer in memory before
        // returning, slowing the whole task to a crawl.
        _ = try await runShellAsAdmin("/usr/sbin/diskutil resetUserPermissions / \(uid) >/dev/null 2>&1")
        return MaintenanceTaskResult(
            success: true,
            summary: "Home directory permissions reset to defaults.",
            duration: Date().timeIntervalSince(start),
            details: nil
        )
    }
}

// MARK: - 6. Rebuild Mail Index

struct RebuildMailIndexTask: MaintenanceTask {
    let id = "rebuild-mail-index"
    let name = "Rebuild Mail Index"
    let description = "Removes Mail.app's envelope index so it rebuilds on next launch."
    let icon = "envelope"
    let estimatedDuration = "Seconds (rebuild on next Mail launch takes longer)"
    let requiresAdmin = false
    var warning: String? {
        "Quit Mail.app before running. Reopening Mail will take longer than usual as it rebuilds its envelope index."
    }

    func dryRun() async -> MaintenanceTaskPreview {
        let urls = envelopeIndexURLs()
        let totalSize = urls.reduce(Int64(0)) { acc, url in
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            return acc + Int64((attrs?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        return MaintenanceTaskPreview(
            description: "Will remove \(urls.count) envelope index file\(urls.count == 1 ? "" : "s") (\(formatBytes(totalSize))).",
            warnings: ["Quit Mail.app first or the rebuild will fail or corrupt the new index."],
            estimatedImpact: .moderate
        )
    }

    func execute() async throws -> MaintenanceTaskResult {
        let start = Date()
        let urls = envelopeIndexURLs()
        var trashed: NSURL?
        for url in urls {
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        }
        return MaintenanceTaskResult(
            success: true,
            summary: "Removed \(urls.count) envelope index file\(urls.count == 1 ? "" : "s"). Mail.app will rebuild on next launch.",
            duration: Date().timeIntervalSince(start),
            details: nil
        )
    }

    private func envelopeIndexURLs() -> [URL] {
        let mailRoot = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Mail", isDirectory: true)
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: mailRoot.path) else {
            return []
        }
        var found: [URL] = []
        for version in versions where version.hasPrefix("V") {
            let mailDataDir = mailRoot
                .appendingPathComponent(version, isDirectory: true)
                .appendingPathComponent("MailData", isDirectory: true)
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: mailDataDir.path) else { continue }
            for entry in entries where entry.hasPrefix("Envelope Index") {
                found.append(mailDataDir.appendingPathComponent(entry))
            }
        }
        return found
    }
}

// MARK: - 7. Clear Font Caches

struct ClearFontCachesTask: MaintenanceTask {
    let id = "clear-font-cache"
    let name = "Clear Font Caches"
    let description = "Resets the font cache database. Useful when fonts render garbled or go missing."
    let icon = "textformat"
    let estimatedDuration = "A few seconds"
    let requiresAdmin = true
    var warning: String? {
        "You'll need to log out and back in for the cache to fully rebuild."
    }

    func dryRun() async -> MaintenanceTaskPreview {
        return MaintenanceTaskPreview(
            description: "Will remove the font registration database and force macOS to rebuild it.",
            warnings: ["Log out and back in after running so apps pick up the rebuilt cache."],
            estimatedImpact: .moderate
        )
    }

    func execute() async throws -> MaintenanceTaskResult {
        let start = Date()
        _ = try await runShellAsAdmin("/usr/bin/atsutil databases -remove")
        return MaintenanceTaskResult(
            success: true,
            summary: "Font caches cleared. Log out and back in for the change to take effect.",
            duration: Date().timeIntervalSince(start),
            details: nil
        )
    }
}
