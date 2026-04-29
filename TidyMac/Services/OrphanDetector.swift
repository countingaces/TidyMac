import Foundation

struct OrphanDetector: Sendable {

    // MARK: - Models

    struct Orphan: Identifiable, Hashable, Sendable {
        let id: UUID
        let bundleId: String
        let inferredName: String
        let paths: [OrphanPath]

        var totalSize: Int64 {
            paths.reduce(Int64(0)) { $0 + $1.size }
        }
    }

    struct OrphanPath: Identifiable, Hashable, Sendable {
        let id: UUID
        let url: URL
        let size: Int64
        let category: AppRemnant.RemnantCategory
    }

    // MARK: - Detection

    /// Scans the standard Library locations for files that appear to belong to
    /// an app that's no longer installed. Items are grouped by inferred bundle
    /// identifier so e.g. `com.foo.app.plist` (Preferences) and `com.foo.app/`
    /// (Caches) for the same removed app fold into one Orphan entry.
    ///
    /// Conservative on purpose: any item whose company prefix
    /// (`com.<vendor>.`) matches a currently installed app is skipped, so
    /// removing Google Earth doesn't flag shared Google data while Chrome is
    /// still installed.
    func detect(installedBundleIds: Set<String>) async -> [Orphan] {
        let preservedPrefixes = buildPreservedPrefixes(from: installedBundleIds)
        var installedSet = Set(installedBundleIds.map { $0.lowercased() })

        // Always treat TidyMac itself as installed, even when running from
        // a path AppDiscoveryService doesn't scan (e.g. Xcode's DerivedData).
        if let me = Bundle.main.bundleIdentifier?.lowercased() {
            installedSet.insert(me)
        }

        let recentlyModifiedCutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let home = URL(fileURLWithPath: NSHomeDirectory())

        struct Plan {
            let location: URL
            let category: AppRemnant.RemnantCategory
            let extractor: (String) -> String?
        }

        let plans: [Plan] = [
            Plan(location: home.appendingPathComponent("Library/Application Support", isDirectory: true),
                 category: .applicationSupport,
                 extractor: { $0 }),
            Plan(location: home.appendingPathComponent("Library/Caches", isDirectory: true),
                 category: .cache,
                 extractor: { $0 }),
            Plan(location: home.appendingPathComponent("Library/Containers", isDirectory: true),
                 category: .container,
                 extractor: { $0 }),
            Plan(location: home.appendingPathComponent("Library/Saved Application State", isDirectory: true),
                 category: .savedState,
                 extractor: {
                     guard $0.hasSuffix(".savedState") else { return nil }
                     return String($0.dropLast(".savedState".count))
                 }),
            Plan(location: home.appendingPathComponent("Library/Preferences", isDirectory: true),
                 category: .preferences,
                 extractor: {
                     guard $0.hasSuffix(".plist") else { return nil }
                     return String($0.dropLast(".plist".count))
                 }),
            Plan(location: home.appendingPathComponent("Library/LaunchAgents", isDirectory: true),
                 category: .launchAgent,
                 extractor: {
                     guard $0.hasSuffix(".plist") else { return nil }
                     return String($0.dropLast(".plist".count))
                 }),
            Plan(location: home.appendingPathComponent("Library/HTTPStorages", isDirectory: true),
                 category: .httpStorage,
                 extractor: { $0 })
        ]

        var grouped: [String: [OrphanPath]] = [:]

        for plan in plans {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: plan.location.path) else { continue }
            for entry in entries {
                if entry.hasPrefix(".") { continue }

                guard var candidateId = plan.extractor(entry) else { continue }

                // Strip "group." for Group Containers if it slipped through
                if candidateId.hasPrefix("group.") {
                    candidateId = String(candidateId.dropFirst("group.".count))
                }

                // Must look like a bundle id (contain at least one dot) so we
                // don't flag generic shared folders like "Google" or "Adobe".
                guard candidateId.contains(".") else { continue }

                // System extension containers (file providers, Safari/Finder
                // extensions, browser helpers, Team-ID-prefixed helpers) live
                // in ~/Library/Containers but can't be removed via
                // NSWorkspace.recycle. Skip them to avoid noisy failures.
                if RemnantScanner.looksLikeSystemExtensionContainer(candidateId) { continue }

                let lowerCandidate = candidateId.lowercased()

                // Apple system files: never flag
                if lowerCandidate.hasPrefix("com.apple.") { continue }

                // Currently installed (exact match): not an orphan
                if installedSet.contains(lowerCandidate) { continue }

                // Shared company prefix still installed: skip the whole namespace
                let candidatePrefix = Self.companyPrefix(of: lowerCandidate)
                if preservedPrefixes.contains(candidatePrefix) { continue }

                let entryURL = plan.location.appendingPathComponent(entry)

                // Skip recently-modified items (might be an install in progress)
                if let modDate = try? entryURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   modDate > recentlyModifiedCutoff {
                    continue
                }

                let isDir = (try? entryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let size: Int64
                if isDir {
                    size = bulkDirectorySize(at: entryURL)
                } else {
                    let attrs = try? entryURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
                    size = Int64(attrs?.totalFileAllocatedSize ?? attrs?.fileSize ?? 0)
                }
                if size <= 0 { continue }

                grouped[candidateId, default: []].append(OrphanPath(
                    id: UUID(),
                    url: entryURL,
                    size: size,
                    category: plan.category
                ))
            }
        }

        return grouped
            .map { (bundleId, paths) in
                Orphan(
                    id: UUID(),
                    bundleId: bundleId,
                    inferredName: Self.inferName(from: bundleId),
                    paths: paths.sorted { $0.size > $1.size }
                )
            }
            .sorted { $0.totalSize > $1.totalSize }
    }

    // MARK: - Helpers

    /// Build the set of "company prefixes" we should never flag as orphans —
    /// any bundle id starting with one of these belongs to a still-installed
    /// app's namespace.
    private func buildPreservedPrefixes(from installedIds: Set<String>) -> Set<String> {
        var preserved: Set<String> = ["com.apple."]
        for id in installedIds {
            preserved.insert(Self.companyPrefix(of: id.lowercased()))
        }
        return preserved
    }

    /// "com.google.Chrome" → "com.google."
    /// "com.spotify"      → "com.spotify."
    /// "single"           → "single."
    private static func companyPrefix(of bundleId: String) -> String {
        let parts = bundleId.split(separator: ".").map(String.init)
        if parts.count >= 2 {
            return parts.prefix(2).joined(separator: ".") + "."
        }
        return bundleId + "."
    }

    /// "com.spotify.client" → "Client"
    /// "com.adobe.Photoshop" → "Photoshop"
    private static func inferName(from bundleId: String) -> String {
        let parts = bundleId.split(separator: ".").map(String.init)
        guard let last = parts.last else { return bundleId }
        // Capitalize if all-lowercase
        if last == last.lowercased() {
            return last.prefix(1).uppercased() + last.dropFirst()
        }
        return last
    }

    private func bulkDirectorySize(at url: URL) -> Int64 {
        var total: Int64 = 0
        do {
            let entries = try BulkDirectoryReader.enumerate(at: url.path)
            for entry in entries {
                if entry.isSymbolicLink { continue }
                if entry.isDirectory {
                    total += bulkDirectorySize(at: url.appendingPathComponent(entry.name, isDirectory: true))
                } else {
                    total += entry.size
                }
            }
        } catch {
            // Permission errors — partial size OK.
        }
        return total
    }
}
