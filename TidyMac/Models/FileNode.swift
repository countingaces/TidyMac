import Foundation

struct FileNode: Identifiable, Hashable {
    let name: String
    let url: URL
    let size: Int64
    let isDirectory: Bool
    let children: [FileNode]

    var id: URL { url }

    var humanReadableSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var fileCount: Int {
        if !isDirectory { return 1 }
        return children.reduce(0) { $0 + $1.fileCount }
    }

    var fileExtension: String? {
        guard !isDirectory else { return nil }
        let ext = url.pathExtension
        return ext.isEmpty ? nil : ext
    }

    static func == (lhs: FileNode, rhs: FileNode) -> Bool {
        lhs.url == rhs.url
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}
