import Foundation
import UniformTypeIdentifiers

struct LargeFile: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let name: String
    let size: Int64
    let kind: FileKind
    let createdDate: Date?
    let modifiedDate: Date?
    /// File access date — proxies "when did the user last open this".
    /// macOS doesn't always update atime (mount option dependent), so
    /// fall back to modified date downstream when this is nil.
    let lastOpenedDate: Date?
    /// True if the file carries the com.apple.quarantine xattr — the
    /// flag macOS sets on anything downloaded from the internet.
    let isDownloaded: Bool
    let finderTags: [String]

    init(
        id: UUID = UUID(),
        url: URL,
        size: Int64,
        kind: FileKind,
        createdDate: Date?,
        modifiedDate: Date?,
        lastOpenedDate: Date?,
        isDownloaded: Bool,
        finderTags: [String]
    ) {
        self.id = id
        self.url = url
        self.name = url.lastPathComponent
        self.size = size
        self.kind = kind
        self.createdDate = createdDate
        self.modifiedDate = modifiedDate
        self.lastOpenedDate = lastOpenedDate
        self.isDownloaded = isDownloaded
        self.finderTags = finderTags
    }

    /// Effective "last touched" date — atime when available, else mtime.
    var effectiveDate: Date? { lastOpenedDate ?? modifiedDate }

    var accessCategory: AccessCategory {
        guard let date = effectiveDate else { return .unknown }
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days > 365 { return .overOneYear }
        if days > 30 { return .overOneMonth }
        if days > 7 { return .overOneWeek }
        return .recent
    }

    var sizeCategory: SizeCategory {
        if size > 1_073_741_824 { return .huge }      // > 1 GB
        if size > 104_857_600 { return .large }        // > 100 MB
        if size > 10_485_760 { return .average }       // > 10 MB
        return .small                                   // 1-10 MB
    }
}

// MARK: - File kind classification

enum FileKind: String, CaseIterable, Hashable, Codable {
    case archive
    case document
    case picture
    case movie
    case music
    case code
    case other

    var displayName: String {
        switch self {
        case .archive: return "Archives"
        case .document: return "Documents"
        case .picture: return "Pictures"
        case .movie: return "Movies"
        case .music: return "Music"
        case .code: return "Code"
        case .other: return "Other"
        }
    }

    var iconSymbol: String {
        switch self {
        case .archive: return "doc.zipper"
        case .document: return "doc.text"
        case .picture: return "photo"
        case .movie: return "film"
        case .music: return "music.note"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .other: return "doc"
        }
    }

    /// Classify a file by UTType when possible (more reliable across
    /// renamed/extension-less files), with a path-extension fallback for
    /// files whose UTType is unset or generic.
    static func classify(_ url: URL, contentType: UTType?) -> FileKind {
        if let type = contentType {
            if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return .archive }
            if type.conforms(to: .movie) || type.conforms(to: .video) { return .movie }
            if type.conforms(to: .image) { return .picture }
            if type.conforms(to: .audio) { return .music }
            if type.conforms(to: .sourceCode) { return .code }
            if type.conforms(to: .pdf)
                || type.conforms(to: .presentation)
                || type.conforms(to: .spreadsheet)
                || type.conforms(to: .compositeContent) {
                return .document
            }
        }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "zip", "tar", "gz", "tgz", "bz2", "xz", "rar", "7z",
             "dmg", "pkg", "iso", "sit", "sitx":
            return .archive
        case "mp4", "mov", "avi", "mkv", "wmv", "m4v", "vob", "flv", "webm", "mpg", "mpeg":
            return .movie
        case "jpg", "jpeg", "png", "heic", "heif", "raw", "cr2", "nef",
             "arw", "dng", "psd", "tiff", "tif", "gif", "webp", "svg", "bmp":
            return .picture
        case "mp3", "m4a", "flac", "wav", "aiff", "aac", "ogg", "opus", "ape", "wma":
            return .music
        case "swift", "py", "js", "ts", "tsx", "jsx", "java", "kt", "rs",
             "cpp", "cc", "c", "h", "hpp", "m", "mm", "go", "rb", "php",
             "json", "xml", "yaml", "yml", "toml", "html", "css", "sh", "bash":
            return .code
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
             "pages", "numbers", "key", "rtf", "txt", "md", "epub":
            return .document
        default:
            return .other
        }
    }
}

enum AccessCategory: String, CaseIterable, Hashable, Codable {
    case overOneYear
    case overOneMonth
    case overOneWeek
    case recent
    case unknown

    var displayName: String {
        switch self {
        case .overOneYear: return "One Year Ago"
        case .overOneMonth: return "One Month Ago"
        case .overOneWeek: return "One Week Ago"
        case .recent: return "Recent"
        case .unknown: return "Unknown"
        }
    }
}

enum SizeCategory: String, CaseIterable, Hashable, Codable {
    case huge
    case large
    case average
    case small

    var displayName: String {
        switch self {
        case .huge: return "Huge"
        case .large: return "Large"
        case .average: return "Average"
        case .small: return "Small"
        }
    }

    var detail: String {
        switch self {
        case .huge: return "> 1 GB"
        case .large: return "100 MB – 1 GB"
        case .average: return "10 – 100 MB"
        case .small: return "1 – 10 MB"
        }
    }
}
