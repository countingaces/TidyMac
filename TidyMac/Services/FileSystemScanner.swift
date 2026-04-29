import Foundation

struct FileSystemScanner: Sendable {
    struct Progress: Sendable {
        let currentDirectory: URL
        let filesScanned: Int
    }

    private let progressIntervalSeconds: Double

    init(progressIntervalSeconds: Double = 0.05) {
        self.progressIntervalSeconds = max(0, progressIntervalSeconds)
    }

    func scan(
        url: URL,
        onProgress: @Sendable @escaping (Progress) -> Void
    ) async throws -> FileNode {
        let counter = Counter()

        var statBuf = stat()
        guard lstat(url.path, &statBuf) == 0 else {
            return FileNode(
                name: url.lastPathComponent,
                url: url,
                size: 0,
                isDirectory: false,
                children: []
            )
        }

        let mode = statBuf.st_mode & S_IFMT
        if mode == S_IFLNK {
            return FileNode(
                name: url.lastPathComponent,
                url: url,
                size: 0,
                isDirectory: false,
                children: []
            )
        }

        if mode == S_IFDIR {
            return try await scanDirectory(url: url, counter: counter, onProgress: onProgress)
        }

        let size = Int64(statBuf.st_size)
        _ = counter.increment()
        return FileNode(
            name: url.lastPathComponent,
            url: url,
            size: size,
            isDirectory: false,
            children: []
        )
    }

    // APFS volume groups mount the data volume both at "/" (via firmlinks for
    // /Users, /Library, /Applications, etc.) AND at /System/Volumes/Data.
    // Recursing the second mount re-traverses every file already visible at "/"
    // and inflates totals into the multi-TB range. Skip the duplicate mount.
    private static let pathsToSkip: Set<String> = [
        "/System/Volumes/Data"
    ]

    private func scanDirectory(
        url: URL,
        counter: Counter,
        onProgress: @Sendable @escaping (Progress) -> Void
    ) async throws -> FileNode {
        try Task.checkCancellation()

        if Self.pathsToSkip.contains(url.path) {
            return FileNode(
                name: url.lastPathComponent,
                url: url,
                size: 0,
                isDirectory: true,
                children: []
            )
        }

        if counter.shouldEmitProgress(minInterval: progressIntervalSeconds) {
            onProgress(Progress(currentDirectory: url, filesScanned: counter.current))
        }

        let entries: [BulkDirectoryEntry]
        do {
            entries = try BulkDirectoryReader.enumerate(at: url.path)
        } catch {
            return try await scanDirectoryFallback(
                url: url,
                counter: counter,
                onProgress: onProgress
            )
        }

        var fileChildren = [FileNode]()
        var subdirURLs = [URL]()
        fileChildren.reserveCapacity(entries.count)

        for entry in entries {
            if entry.name.isEmpty { continue }
            if entry.isSymbolicLink { continue }
            if entry.name.hasPrefix(".") { continue }

            let childURL = url.appendingPathComponent(entry.name, isDirectory: entry.isDirectory)

            if entry.isDirectory {
                subdirURLs.append(childURL)
            } else {
                _ = counter.increment()
                fileChildren.append(FileNode(
                    name: entry.name,
                    url: childURL,
                    size: entry.size,
                    isDirectory: false,
                    children: []
                ))
            }
        }

        var subdirNodes = [FileNode]()
        if !subdirURLs.isEmpty {
            subdirNodes.reserveCapacity(subdirURLs.count)
            try await withThrowingTaskGroup(of: FileNode.self) { group in
                for sub in subdirURLs {
                    group.addTask {
                        try await self.scanDirectory(
                            url: sub,
                            counter: counter,
                            onProgress: onProgress
                        )
                    }
                }
                for try await node in group {
                    try Task.checkCancellation()
                    subdirNodes.append(node)
                }
            }
        }

        var allChildren = fileChildren
        allChildren.append(contentsOf: subdirNodes)
        let totalSize = saturatingSum(allChildren)

        return FileNode(
            name: url.lastPathComponent,
            url: url,
            size: totalSize,
            isDirectory: true,
            children: allChildren.sorted { $0.size > $1.size }
        )
    }

    private static let fallbackKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .totalFileAllocatedSizeKey
    ]

    private func scanDirectoryFallback(
        url: URL,
        counter: Counter,
        onProgress: @Sendable @escaping (Progress) -> Void
    ) async throws -> FileNode {
        try Task.checkCancellation()

        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: Array(Self.fallbackKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        } catch {
            return FileNode(
                name: url.lastPathComponent,
                url: url,
                size: 0,
                isDirectory: true,
                children: []
            )
        }

        var fileChildren = [FileNode]()
        var subdirURLs = [URL]()
        fileChildren.reserveCapacity(contents.count)

        for childURL in contents {
            guard let v = try? childURL.resourceValues(forKeys: Self.fallbackKeys),
                  v.isSymbolicLink != true
            else { continue }

            if v.isDirectory == true {
                subdirURLs.append(childURL)
            } else {
                let size = Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
                _ = counter.increment()
                fileChildren.append(FileNode(
                    name: childURL.lastPathComponent,
                    url: childURL,
                    size: size,
                    isDirectory: false,
                    children: []
                ))
            }
        }

        var subdirNodes = [FileNode]()
        if !subdirURLs.isEmpty {
            subdirNodes.reserveCapacity(subdirURLs.count)
            try await withThrowingTaskGroup(of: FileNode.self) { group in
                for sub in subdirURLs {
                    group.addTask {
                        try await self.scanDirectory(
                            url: sub,
                            counter: counter,
                            onProgress: onProgress
                        )
                    }
                }
                for try await node in group {
                    try Task.checkCancellation()
                    subdirNodes.append(node)
                }
            }
        }

        var allChildren = fileChildren
        allChildren.append(contentsOf: subdirNodes)
        let totalSize = saturatingSum(allChildren)

        return FileNode(
            name: url.lastPathComponent,
            url: url,
            size: totalSize,
            isDirectory: true,
            children: allChildren.sorted { $0.size > $1.size }
        )
    }
}

@inline(__always)
private func saturatingSum(_ nodes: [FileNode]) -> Int64 {
    var total: Int64 = 0
    for node in nodes {
        let (sum, overflow) = total.addingReportingOverflow(node.size)
        total = overflow ? .max : sum
    }
    return total
}

private final class Counter: @unchecked Sendable {
    private var value = 0
    private var lastEmit: TimeInterval = 0
    private let lock = NSLock()

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    func shouldEmitProgress(minInterval: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSinceReferenceDate
        if now - lastEmit >= minInterval {
            lastEmit = now
            return true
        }
        return false
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
