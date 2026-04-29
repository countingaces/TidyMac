import Foundation
import AppKit

final class CleaningService {

    struct CleaningResult {
        let itemsCleaned: Int
        let totalSizeFreed: Int64
        let failures: [(URL, Error)]
        let log: [CleaningLogEntry]
        let logFileURL: URL?
    }

    struct CleaningLogEntry {
        let timestamp: Date
        let action: CleanAction
        let path: URL
        let size: Int64
        let success: Bool
        let error: String?
    }

    enum CleanAction: String {
        case movedToTrash
        case skipped
        case failed
    }

    struct Progress: Sendable {
        let currentItemName: String
        let itemsCompleted: Int
        let totalItems: Int
        let sizeFreedSoFar: Int64
    }

    enum CleaningError: LocalizedError {
        case recycleFailed
        case cancelled
        case simctlFailed(String)

        var errorDescription: String? {
            switch self {
            case .recycleFailed: return "macOS refused to move the item to Trash."
            case .cancelled:     return "Cleaning was cancelled."
            case .simctlFailed(let detail): return detail
            }
        }
    }

    // MARK: - Pre-flight

    /// Returns running apps whose bundle identifiers match items the user wants to clean.
    static func conflictingRunningApps(for items: [JunkItem]) -> [NSRunningApplication] {
        let conflictingIds = Set(items.compactMap { $0.appBundleId })
        guard !conflictingIds.isEmpty else { return [] }
        return NSWorkspace.shared.runningApplications.filter { app in
            guard let id = app.bundleIdentifier else { return false }
            return conflictingIds.contains(id)
        }
    }

    static func quit(_ app: NSRunningApplication) {
        app.terminate()
    }

    static func quitAll(_ apps: [NSRunningApplication]) {
        for app in apps {
            app.terminate()
        }
    }

    // MARK: - Cleaning

    func clean<T: ScanResult>(
        items: [T],
        onProgress: @Sendable @escaping (Progress) -> Void
    ) async -> CleaningResult {
        var entries: [CleaningLogEntry] = []
        var failures: [(URL, Error)] = []
        var sizeFreed: Int64 = 0
        var itemsCleaned = 0
        var cancelledMidway = false

        for (idx, item) in items.enumerated() {
            if Task.isCancelled {
                cancelledMidway = true
                for remaining in items[idx...] {
                    entries.append(CleaningLogEntry(
                        timestamp: Date(),
                        action: .skipped,
                        path: remaining.path,
                        size: remaining.size,
                        success: false,
                        error: "Cancelled"
                    ))
                }
                break
            }

            onProgress(Progress(
                currentItemName: item.name,
                itemsCompleted: idx,
                totalItems: items.count,
                sizeFreedSoFar: sizeFreed
            ))

            do {
                try await trashItem(at: item.path)
                sizeFreed += item.size
                itemsCleaned += 1
                entries.append(CleaningLogEntry(
                    timestamp: Date(),
                    action: .movedToTrash,
                    path: item.path,
                    size: item.size,
                    success: true,
                    error: nil
                ))
            } catch {
                failures.append((item.path, error))
                entries.append(CleaningLogEntry(
                    timestamp: Date(),
                    action: .failed,
                    path: item.path,
                    size: item.size,
                    success: false,
                    error: error.localizedDescription
                ))
            }
        }

        if !cancelledMidway {
            onProgress(Progress(
                currentItemName: "",
                itemsCompleted: items.count,
                totalItems: items.count,
                sizeFreedSoFar: sizeFreed
            ))
        }

        let logURL = try? saveLog(entries: entries, itemsCleaned: itemsCleaned, sizeFreed: sizeFreed, failureCount: failures.count)

        return CleaningResult(
            itemsCleaned: itemsCleaned,
            totalSizeFreed: sizeFreed,
            failures: failures,
            log: entries,
            logFileURL: logURL
        )
    }

    private func trashItem(at url: URL) async throws {
        // Items already in the Trash get permanently removed — there's no
        // "deeper Trash" to send them to, and NSWorkspace.recycle would just
        // rename them in place without freeing space. Everything else is
        // moved to the Trash so the user can recover it.
        if Self.isInTrash(url) {
            try FileManager.default.removeItem(at: url)
            return
        }

        // iOS/watchOS/tvOS/xrOS simulator runtimes are root-owned and live in
        // /Library/Developer/CoreSimulator/Volumes/. NSWorkspace.recycle can't
        // touch them. Route the delete through `xcrun simctl runtime delete`
        // which talks to Apple's CoreSimulator daemon (already privileged).
        if let build = Self.simulatorRuntimeBuild(from: url) {
            try await deleteSimulatorRuntime(build: build)
            return
        }

        // Simulator devices are at ~/Library/Developer/CoreSimulator/Devices/<UUID>/
        // and are also managed by the CoreSimulator daemon.
        if let uuid = Self.simulatorDeviceUUID(from: url) {
            try await deleteSimulatorDevice(uuid: uuid)
            return
        }

        do {
            try await recycleViaWorkspace(url)
        } catch {
            // For /Applications/*.app paths that NSWorkspace can't move on
            // its own (Mac App Store apps with _MASReceipt, third-party
            // installers that set restrictive ACLs, etc.), retry via Finder.
            // Finder triggers macOS's standard admin-auth prompt when needed
            // — the same prompt you get when dragging an app to Trash from
            // Finder normally.
            if Self.shouldRetryViaFinder(url) {
                try await deleteViaFinder(url)
                return
            }
            throw error
        }
    }

    private func recycleViaWorkspace(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.recycle([url]) { newURLs, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if newURLs.isEmpty {
                    continuation.resume(throwing: CleaningError.recycleFailed)
                    return
                }
                continuation.resume(returning: ())
            }
        }
    }

    /// Only escalate to Finder for top-level .app bundles in /Applications/
    /// or /Applications/Utilities/. Anywhere else (containers, prefs, etc.)
    /// is owned by the user and either succeeds via NSWorkspace or fails
    /// because the item is system-managed — Finder doesn't help with those.
    private static func shouldRetryViaFinder(_ url: URL) -> Bool {
        guard url.pathExtension == "app" else { return false }
        let path = url.path
        return path.hasPrefix("/Applications/")
            || path.hasPrefix("/Applications/Utilities/")
    }

    /// Ask Finder (via osascript) to move the item to Trash. Finder is
    /// allowed to escalate to admin auth when it needs to — that's how the
    /// drag-to-Trash flow handles Mac App Store apps. The first time TidyMac
    /// sends an Apple Event to Finder, macOS shows a Privacy & Security ➜
    /// Automation prompt; user must allow Finder control for this to work.
    private func deleteViaFinder(_ url: URL) async throws {
        let escaped = url.path.replacingOccurrences(of: "\"", with: "\\\"")
        // Move-to-Trash, capture any AppleScript error so we can surface it.
        let script = """
        tell application "Finder"
            try
                delete (POSIX file "\(escaped)" as alias)
                return "OK"
            on error errMsg number errNum
                return "ERR " & errNum & ": " & errMsg
            end try
        end tell
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw CleaningError.simctlFailed(
                "Couldn't launch osascript to retry via Finder: \(error.localizedDescription)"
            )
        }
        process.waitUntilExit()

        // Source of truth: did the file actually go away?
        if !FileManager.default.fileExists(atPath: url.path) {
            return
        }

        // Otherwise, surface the most informative error we have.
        let outStr = (String(data: stdout.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let errStr = (String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let combined = errStr.isEmpty ? outStr : errStr
        if combined.contains("-1743") || combined.contains("Not authorized") {
            throw CleaningError.simctlFailed(
                "TidyMac needs permission to control Finder. Open System Settings → Privacy & Security → Automation, expand TidyMac, and enable Finder. Then try again."
            )
        }
        if combined.contains("-128") || combined.localizedCaseInsensitiveContains("cancel") {
            throw CleaningError.simctlFailed("Authorization cancelled.")
        }
        if combined.isEmpty {
            throw CleaningError.recycleFailed
        }
        throw CleaningError.simctlFailed("Finder couldn't move \(url.lastPathComponent) to Trash: \(combined)")
    }

    private static func isInTrash(_ url: URL) -> Bool {
        let path = url.path
        let homeTrash = NSHomeDirectory() + "/.Trash"
        if path == homeTrash || path.hasPrefix(homeTrash + "/") { return true }
        if path.hasPrefix("/Volumes/") && path.range(of: "/.Trashes/") != nil { return true }
        return false
    }

    // MARK: - Simulator deletion via xcrun simctl

    /// Returns the build version (e.g. "22G86") if the URL refers to a
    /// simulator runtime volume root like /Library/Developer/CoreSimulator/Volumes/iOS_22G86.
    private static func simulatorRuntimeBuild(from url: URL) -> String? {
        let parent = url.deletingLastPathComponent().path
        guard parent == "/Library/Developer/CoreSimulator/Volumes" else { return nil }
        let last = url.lastPathComponent
        let prefixes = ["iOS_", "watchOS_", "tvOS_", "xrOS_", "visionOS_", "macOS_"]
        for prefix in prefixes where last.hasPrefix(prefix) {
            return String(last.dropFirst(prefix.count))
        }
        return nil
    }

    /// Returns the device UUID if the URL refers to a simulator device root.
    private static func simulatorDeviceUUID(from url: URL) -> String? {
        let devicesRoot = NSHomeDirectory() + "/Library/Developer/CoreSimulator/Devices"
        guard url.deletingLastPathComponent().path == devicesRoot else { return nil }
        let last = url.lastPathComponent
        // Loose UUID check — 8-4-4-4-12 hex layout.
        guard last.count == 36 else { return nil }
        let parts = last.split(separator: "-").map(String.init)
        let lengths = [8, 4, 4, 4, 12]
        guard parts.count == 5,
              zip(parts, lengths).allSatisfy({ $0.count == $1 })
        else { return nil }
        return last
    }

    private var runtimeUUIDByBuild: [String: String]?

    private func deleteSimulatorRuntime(build: String) async throws {
        if runtimeUUIDByBuild == nil {
            runtimeUUIDByBuild = try await fetchRuntimeUUIDMap()
        }
        guard let uuid = runtimeUUIDByBuild?[build] else {
            throw CleaningError.simctlFailed(
                "Simulator runtime with build \(build) not found in `xcrun simctl runtime list`."
            )
        }
        try await runSimctl(["runtime", "delete", uuid])
        // The deleted runtime won't be re-listed; clear the cache so a
        // subsequent rescan picks up the actual current state.
        runtimeUUIDByBuild = nil
    }

    private func deleteSimulatorDevice(uuid: String) async throws {
        try await runSimctl(["delete", uuid])
    }

    private func fetchRuntimeUUIDMap() async throws -> [String: String] {
        let stdout = try await runSimctlCapturing(["runtime", "list", "-j"])
        guard let data = stdout.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }

        var map: [String: String] = [:]
        for (uuid, value) in json {
            if let runtime = value as? [String: Any],
               let build = runtime["build"] as? String {
                map[build] = uuid
            }
        }
        return map
    }

    @discardableResult
    private func runSimctl(_ arguments: [String]) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            throw CleaningError.simctlFailed("Couldn't launch xcrun: \(error.localizedDescription)")
        }
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "exit \(process.terminationStatus)"
            throw CleaningError.simctlFailed("simctl \(arguments.joined(separator: " ")) — \(errMsg)")
        }
        return process.terminationStatus
    }

    private func runSimctlCapturing(_ arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw CleaningError.simctlFailed("Couldn't launch xcrun: \(error.localizedDescription)")
        }
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw CleaningError.simctlFailed("simctl exit \(process.terminationStatus)")
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Log persistence

    private func saveLog(
        entries: [CleaningLogEntry],
        itemsCleaned: Int,
        sizeFreed: Int64,
        failureCount: Int
    ) throws -> URL {
        let logsURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/TidyMac/Logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let safeStamp = isoFormatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let logURL = logsURL.appendingPathComponent("clean-\(safeStamp).log")

        var output = ""
        output += "TidyMac Cleaning Log\n"
        output += "Date: \(Date())\n"
        output += "Items cleaned: \(itemsCleaned)\n"
        output += "Size freed: \(ByteCountFormatter.string(fromByteCount: sizeFreed, countStyle: .file))\n"
        output += "Failures: \(failureCount)\n"
        output += String(repeating: "-", count: 60) + "\n\n"

        for entry in entries {
            let time = isoFormatter.string(from: entry.timestamp)
            let size = ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
            output += "[\(time)] \(entry.action.rawValue) — \(size) — \(entry.path.path)"
            if let err = entry.error {
                output += "\n    ERROR: \(err)"
            }
            output += "\n"
        }

        try output.write(to: logURL, atomically: true, encoding: .utf8)
        return logURL
    }
}
