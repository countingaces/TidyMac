import Foundation
import UniformTypeIdentifiers

/// Walks the user's home directory looking for files ≥1 MB and emits
/// LargeFile values via an AsyncStream as they're found. Streaming
/// (rather than returning the full array at the end) lets the UI start
/// rendering biggest-first results within seconds while the long tail
/// continues in the background.
///
/// Excludes ~/Library (covered by System Junk), ~/.Trash (covered by
/// the Trash module), and hidden directories — except ~/.local/share
/// which can hold large game data the user might want to clean.
struct LargeFileScanner: Sendable {

    /// Smallest file we'll surface. Files below this aren't worth the
    /// user's attention or our render budget.
    static let minimumSize: Int64 = 1_048_576 // 1 MB

    struct Progress: Sendable, Equatable {
        let filesFound: Int
        let totalSize: Int64
        let currentDirectory: String
    }

    func scan(
        progress onProgress: @Sendable @escaping (Progress) -> Void
    ) -> AsyncStream<LargeFile> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await Self.run(yield: { file in
                    continuation.yield(file)
                }, onProgress: onProgress)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Walk

    private static func run(
        yield: @Sendable (LargeFile) -> Void,
        onProgress: @Sendable (Progress) -> Void
    ) async {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let resourceKeys: Set<URLResourceKey> = [
            .fileSizeKey,
            .totalFileAllocatedSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
            .contentAccessDateKey,
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .typeIdentifierKey,
            .quarantinePropertiesKey,
            .tagNamesKey
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: home,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true } // ignore errors, keep walking
        ) else { return }

        var filesFound = 0
        var totalSize: Int64 = 0
        var lastReportedDir = ""
        var sinceLastReport = 0

        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { return }

            // Directory pruning
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                if shouldSkipDirectory(url, home: home) {
                    enumerator.skipDescendants()
                }
                let path = url.path
                if path != lastReportedDir {
                    lastReportedDir = path
                    onProgress(Progress(
                        filesFound: filesFound,
                        totalSize: totalSize,
                        currentDirectory: relativePath(path, home: home)
                    ))
                }
                continue
            }

            guard let values = try? url.resourceValues(forKeys: resourceKeys) else { continue }

            // Skip symlinks — following them risks loops and double-counts.
            if values.isSymbolicLink == true { continue }
            // Only regular files.
            if values.isRegularFile != true { continue }

            // Use allocated size when available (matches Finder's
            // "Size on disk"), fall back to logical size.
            let size = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            if size < minimumSize { continue }

            let utType = values.typeIdentifier.flatMap { UTType($0) }
            let kind = FileKind.classify(url, contentType: utType)

            let isDownloaded = (values.allValues[.quarantinePropertiesKey] as? [String: Any]) != nil

            let tags = (values.allValues[.tagNamesKey] as? [String]) ?? []

            let file = LargeFile(
                url: url,
                size: size,
                kind: kind,
                createdDate: values.creationDate,
                modifiedDate: values.contentModificationDate,
                lastOpenedDate: values.contentAccessDate,
                isDownloaded: isDownloaded,
                finderTags: tags
            )

            yield(file)
            filesFound += 1
            totalSize += size
            sinceLastReport += 1
            // Throttle progress callbacks — every 25 files is plenty
            // for the UI; flooding @MainActor with updates is wasteful.
            if sinceLastReport >= 25 {
                sinceLastReport = 0
                onProgress(Progress(
                    filesFound: filesFound,
                    totalSize: totalSize,
                    currentDirectory: relativePath(url.deletingLastPathComponent().path, home: home)
                ))
            }
        }

        // Final progress tick so the UI sees the totals on completion.
        onProgress(Progress(
            filesFound: filesFound,
            totalSize: totalSize,
            currentDirectory: ""
        ))
    }

    // MARK: - Exclusions

    /// Decide whether to descend into a directory. Library is covered by
    /// System Junk, Trash by its own module, hidden dirs are too noisy
    /// — except ~/.local/share which Steam/Lutris/etc. fill with game
    /// data worth flagging.
    private static func shouldSkipDirectory(_ url: URL, home: URL) -> Bool {
        let relative = url.path.dropFirst(home.path.count)

        // Exact-prefix exclusions under home
        let excluded = [
            "/Library",
            "/.Trash",
            "/.cache",
            "/.npm",
            "/.cocoapods",
            "/Library/Caches"
        ]
        for prefix in excluded {
            if relative == prefix || relative.hasPrefix(prefix + "/") { return true }
        }

        // Generic hidden-dir skip, with the .local/share carve-out.
        let last = url.lastPathComponent
        if last.hasPrefix(".") {
            // Allow .local (so .local/share is reachable) and .local/share itself.
            if last == ".local" { return false }
            if last == "share" && url.deletingLastPathComponent().lastPathComponent == ".local" {
                return false
            }
            return true
        }

        return false
    }

    /// "/Users/ryan/Movies/foo" → "Movies/foo"
    private static func relativePath(_ path: String, home: URL) -> String {
        let prefix = home.path + "/"
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return path
    }
}
