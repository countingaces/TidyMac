import Foundation

struct JunkItem: ScanResult {
    let id: UUID
    let name: String
    let path: URL
    let size: Int64
    let safetyLevel: SafetyLevel
    let categoryId: String
    let lastModified: Date?
    let appBundleId: String?

    init(
        id: UUID = UUID(),
        name: String,
        path: URL,
        size: Int64,
        safetyLevel: SafetyLevel,
        categoryId: String,
        lastModified: Date? = nil,
        appBundleId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.size = size
        self.safetyLevel = safetyLevel
        self.categoryId = categoryId
        self.lastModified = lastModified
        self.appBundleId = appBundleId
    }

    var humanReadableSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// Items in a system-owned location need the privileged helper
    /// to delete. Computed (not stored) so we can derive it from the
    /// shared HelperPaths constants — what the badge says is exactly
    /// what the helper will accept.
    var requiresAdmin: Bool {
        HelperPaths.validate(path.path).allowed
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: JunkItem, rhs: JunkItem) -> Bool {
        lhs.id == rhs.id
    }
}
