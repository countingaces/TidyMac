import Foundation
import ServiceManagement

/// App-side gateway to the privileged helper. Owns the install /
/// status / connection lifecycle and exposes a small async API the
/// rest of the app can call without thinking about XPC.
///
/// Singleton because:
///   - Status is global ("is the helper installed right now?").
///   - The XPC connection is expensive to set up and pools cleanly.
///   - SwiftUI views consume the @Published state via .shared.
@MainActor
final class PrivilegedHelperManager: ObservableObject {

    static let shared = PrivilegedHelperManager()

    @Published private(set) var status: HelperStatus = .unknown

    enum HelperStatus: Equatable {
        case unknown
        case notInstalled
        case installed(version: String)
        case needsUpdate(installedVersion: String, requiredVersion: String)
        case error(String)
    }

    enum HelperError: LocalizedError {
        case notInstalled
        case communicationFailed(String)
        case operationFailed(String)
        case authorizationCancelled

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "TidyMac's Helper Tool isn't installed. Open Settings → Helper Tool to install it."
            case .communicationFailed(let detail):
                return "Couldn't talk to the Helper Tool: \(detail)"
            case .operationFailed(let detail):
                return "The Helper Tool refused the operation: \(detail)"
            case .authorizationCancelled:
                return "Helper installation was cancelled."
            }
        }
    }

    private var connection: NSXPCConnection?

    /// Public accessor for the Settings UI's "Allowed Locations"
    /// disclosure. Reading directly from HelperPaths means the user
    /// sees what the running helper enforces, not a hand-curated
    /// summary that could drift.
    var allowedPrefixes: [String] { HelperPaths.allowedPrefixes }
    var deniedPrefixes: [String] { HelperPaths.deniedPrefixes }

    private init() {}

    // MARK: - Status

    /// Tries to talk to the helper and resolves its current status.
    /// Called on app launch and after install / uninstall actions.
    func refreshStatus() async {
        // Without a real Developer ID the connection check will fail
        // even when the bits are technically installed — there's no
        // way to make XPC accept an ad-hoc-signed caller. Surface
        // that as .notInstalled so the UI reads "Install Helper"
        // rather than "Helper is broken".
        do {
            let version = try await fetchHelperVersion()
            if version == kTidyMacHelperVersion {
                status = .installed(version: version)
            } else {
                status = .needsUpdate(installedVersion: version,
                                      requiredVersion: kTidyMacHelperVersion)
            }
        } catch {
            status = .notInstalled
        }
    }

    // MARK: - Install / uninstall

    /// Registers the helper via SMAppService.daemon. macOS prompts
    /// the user for their admin password once, then validates the
    /// helper's code signature, copies it from inside the app bundle
    /// to /Library/PrivilegedHelperTools/, and starts launchd
    /// supervision. Persists across reboots.
    ///
    /// Without a Developer ID this call returns
    /// `.invalidSignature` — that's expected and surfaced as a clear
    /// error rather than a silent failure.
    func install() async throws {
        guard #available(macOS 13.0, *) else {
            throw HelperError.communicationFailed("SMAppService requires macOS 13 or later.")
        }
        let service = SMAppService.daemon(plistName: kTidyMacHelperPlistName)
        do {
            try service.register()
        } catch {
            // SMAppService throws NSError values whose .code maps to
            // SMAppService.Error values on macOS 13+. Surface the
            // error description as-is — Apple's strings are clearer
            // than anything we'd write.
            status = .error(error.localizedDescription)
            throw HelperError.operationFailed(error.localizedDescription)
        }
        await refreshStatus()
    }

    /// Cleanly removes the helper from /Library/PrivilegedHelperTools/
    /// and deregisters it from launchd. Worth offering even when
    /// installation works — open-source tools should leave nothing
    /// behind on uninstall.
    func uninstall() async throws {
        guard #available(macOS 13.0, *) else { return }
        invalidateConnection()
        let service = SMAppService.daemon(plistName: kTidyMacHelperPlistName)
        do {
            try await service.unregister()
        } catch {
            throw HelperError.operationFailed(error.localizedDescription)
        }
        status = .notInstalled
    }

    // MARK: - Operations

    /// Trashes a root-owned item via the helper. Routes to the
    /// helper's own quarantine area at /Library/Logs/TidyMac/HelperTrash
    /// since the user's ~/.Trash can't accept root-owned files.
    func moveRootOwnedItemToTrash(at url: URL) async throws {
        let helper = try await proxy()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            helper.moveItemToTrash(atPath: url.path) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: HelperError.operationFailed(error ?? "Unknown error"))
                }
            }
        }
    }

    /// Permanently deletes a root-owned item via the helper. Use
    /// only for items that don't fit in the helper's quarantine
    /// (very large files). Default to moveRootOwnedItemToTrash.
    func removeRootOwnedItem(at url: URL) async throws {
        let helper = try await proxy()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            helper.removeItem(atPath: url.path) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: HelperError.operationFailed(error ?? "Unknown error"))
                }
            }
        }
    }

    // MARK: - XPC plumbing

    /// Builds (or reuses) an XPC connection to the helper and returns
    /// the strongly-typed proxy. Connection invalidation handlers
    /// reset our cached connection so the next call rebuilds.
    private func proxy() async throws -> HelperToolProtocol {
        let connection = activeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            // Errors flow through the explicit reply on each method;
            // this handler is a backstop for systemic XPC failures.
        }) as? HelperToolProtocol else {
            throw HelperError.communicationFailed("Couldn't acquire helper proxy.")
        }
        return proxy
    }

    private func activeConnection() -> NSXPCConnection {
        if let connection { return connection }
        let connection = NSXPCConnection(
            machServiceName: kTidyMacHelperMachServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: HelperToolProtocol.self)
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    private func invalidateConnection() {
        connection?.invalidate()
        connection = nil
    }

    private func fetchHelperVersion() async throws -> String {
        let helper = try await proxy()
        return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            helper.getHelperVersion { version in
                continuation.resume(returning: version)
            }
        }
    }
}
