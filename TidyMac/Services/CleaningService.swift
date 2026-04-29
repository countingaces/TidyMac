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

        var errorDescription: String? {
            switch self {
            case .recycleFailed: return "macOS refused to move the item to Trash."
            case .cancelled:     return "Cleaning was cancelled."
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

    private static func isInTrash(_ url: URL) -> Bool {
        let path = url.path
        let homeTrash = NSHomeDirectory() + "/.Trash"
        if path == homeTrash || path.hasPrefix(homeTrash + "/") { return true }
        if path.hasPrefix("/Volumes/") && path.range(of: "/.Trashes/") != nil { return true }
        return false
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
