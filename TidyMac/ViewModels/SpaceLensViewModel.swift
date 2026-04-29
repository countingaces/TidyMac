import Foundation
import SwiftUI
import AppKit

@MainActor
final class SpaceLensViewModel: ObservableObject {
    struct ScanProgress: Equatable {
        var currentDirectory: String
        var filesScanned: Int
    }

    enum ScanState: Equatable {
        case landing
        case scanning(ScanProgress)
        case results
    }

    struct DiskInfo: Equatable {
        let name: String
        let totalBytes: Int64
        let availableBytes: Int64

        var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    }

    @Published private(set) var scanState: ScanState = .landing
    @Published private(set) var rootNode: FileNode?
    @Published private(set) var currentPath: [FileNode] = []
    @Published var selectedItems: Set<FileNode.ID> = []
    @Published private(set) var filesScanned: Int = 0
    @Published private(set) var diskInfo: DiskInfo?
    @Published private(set) var isRemoving: Bool = false
    @Published var removeAlertMessage: String?

    private var scanTask: Task<Void, Never>?
    private let scanner = FileSystemScanner()

    init() {
        refreshDiskInfo()
    }

    var currentNode: FileNode? {
        currentPath.last ?? rootNode
    }

    var selectedSize: Int64 {
        guard let current = currentNode else { return 0 }
        return current.children
            .filter { selectedItems.contains($0.id) }
            .reduce(0) { $0 + $1.size }
    }

    func refreshDiskInfo() {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return }

        let name = values.volumeName ?? "Macintosh HD"
        let total = Int64(values.volumeTotalCapacity ?? 0)
        let available = values.volumeAvailableCapacityForImportantUsage
            ?? Int64(values.volumeAvailableCapacity ?? 0)

        diskInfo = DiskInfo(
            name: name,
            totalBytes: total,
            availableBytes: available
        )
    }

    func startScan(url: URL) {
        scanTask?.cancel()

        scanState = .scanning(ScanProgress(
            currentDirectory: url.path,
            filesScanned: 0
        ))
        filesScanned = 0
        selectedItems = []
        rootNode = nil
        currentPath = []

        let scanner = self.scanner

        scanTask = Task { [weak self] in
            do {
                let node = try await scanner.scan(url: url) { progress in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard case .scanning = self.scanState else { return }
                        self.filesScanned = progress.filesScanned
                        self.scanState = .scanning(ScanProgress(
                            currentDirectory: progress.currentDirectory.path,
                            filesScanned: progress.filesScanned
                        ))
                    }
                }

                guard !Task.isCancelled else { return }

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.rootNode = node
                    self.currentPath = []
                    self.filesScanned = node.fileCount
                    self.scanState = .results
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    self?.scanState = .landing
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.scanState = .landing
                }
            }
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        scanState = .landing
    }

    func navigateInto(node: FileNode) {
        guard node.isDirectory else { return }
        currentPath.append(node)
        selectedItems.removeAll()
    }

    func navigateUp() {
        guard !currentPath.isEmpty else { return }
        currentPath.removeLast()
        selectedItems.removeAll()
    }

    func navigate(toDepth depth: Int) {
        let clamped = max(0, min(depth, currentPath.count))
        guard clamped != currentPath.count else { return }
        currentPath = Array(currentPath.prefix(clamped))
        selectedItems.removeAll()
    }

    func selectItem(node: FileNode) {
        if selectedItems.contains(node.id) {
            selectedItems.remove(node.id)
        } else {
            selectedItems.insert(node.id)
        }
    }

    func removeSelected() async {
        guard !isRemoving else { return }
        guard let current = currentNode else { return }

        let toRemove = current.children.filter { selectedItems.contains($0.id) }
        guard !toRemove.isEmpty else { return }

        isRemoving = true
        defer { isRemoving = false }

        let urls = toRemove.map { $0.url }
        let (trashed, error) = await Self.recycle(urls: urls)
        let removedIDs = Set(trashed.keys)

        if removedIDs.isEmpty {
            let detail = error?.localizedDescription
                ?? "macOS refused to move the selected items to Trash. They may be in a protected location or owned by another user."
            removeAlertMessage = "Couldn't move \(urls.count) item\(urls.count == 1 ? "" : "s") to Trash.\n\n\(detail)"
            return
        }

        let removedSize = toRemove
            .filter { removedIDs.contains($0.id) }
            .reduce(Int64(0)) { $0 + $1.size }

        let newCurrentChildren = current.children.filter { !removedIDs.contains($0.id) }
        let newCurrent = FileNode(
            name: current.name,
            url: current.url,
            size: max(0, current.size - removedSize),
            isDirectory: current.isDirectory,
            children: newCurrentChildren
        )

        if let root = rootNode {
            let pathIDs = currentPath.map { $0.id }
            let newRoot = Self.replaceNode(in: root, atPath: pathIDs, with: newCurrent, sizeDelta: -removedSize)
            rootNode = newRoot
            currentPath = Self.rebuildPath(in: newRoot, ids: pathIDs)
        }

        selectedItems.subtract(removedIDs)
        refreshDiskInfo()

        if removedIDs.count < urls.count {
            let failed = urls.count - removedIDs.count
            let detail = error?.localizedDescription ?? "Some items were skipped."
            removeAlertMessage = "Removed \(removedIDs.count) item\(removedIDs.count == 1 ? "" : "s"). \(failed) couldn't be moved to Trash.\n\n\(detail)"
        }
    }

    private static func recycle(urls: [URL]) async -> ([URL: URL], Error?) {
        await withCheckedContinuation { continuation in
            NSWorkspace.shared.recycle(urls) { newURLs, error in
                continuation.resume(returning: (newURLs, error))
            }
        }
    }

    private static func replaceNode(
        in tree: FileNode,
        atPath ids: [FileNode.ID],
        with newNode: FileNode,
        sizeDelta: Int64
    ) -> FileNode {
        guard !ids.isEmpty else { return newNode }

        let firstID = ids[0]
        let restIDs = Array(ids.dropFirst())

        var newChildren = tree.children
        if let idx = newChildren.firstIndex(where: { $0.id == firstID }) {
            newChildren[idx] = replaceNode(
                in: newChildren[idx],
                atPath: restIDs,
                with: newNode,
                sizeDelta: sizeDelta
            )
        }

        return FileNode(
            name: tree.name,
            url: tree.url,
            size: max(0, tree.size + sizeDelta),
            isDirectory: tree.isDirectory,
            children: newChildren.sorted { $0.size > $1.size }
        )
    }

    private static func rebuildPath(in tree: FileNode, ids: [FileNode.ID]) -> [FileNode] {
        var path: [FileNode] = []
        var cursor = tree
        for id in ids {
            guard let next = cursor.children.first(where: { $0.id == id }) else {
                return path
            }
            path.append(next)
            cursor = next
        }
        return path
    }

    func returnToLanding() {
        scanTask?.cancel()
        scanTask = nil
        rootNode = nil
        currentPath = []
        selectedItems = []
        filesScanned = 0
        scanState = .landing
    }
}
