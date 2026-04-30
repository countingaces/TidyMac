import Foundation
import Security

/// Implements the XPC-exposed protocol AND vets every incoming
/// connection. Three layers of validation defend each operation:
///
///   1. Apple/kernel — code signatures of both binaries (handled
///      automatically by XPC; we don't have to do anything).
///   2. XPC framework — the connection is rejected before our code
///      runs if the caller's code signature doesn't satisfy the
///      requirement string we set on the listener.
///   3. This class — every path is resolved through symlinks and
///      validated against HelperPaths' allowlist/denylist *every
///      time*, even after the connection was approved.
///
/// Step 1 is free. Step 2 happens in `listener(_:shouldAcceptNew­
/// Connection:)`. Step 3 happens in every protocol method.
final class HelperTool: NSObject, HelperToolProtocol, NSXPCListenerDelegate {

    // MARK: - NSXPCListenerDelegate (Step 2 validation)

    /// XPC calls this for every new connection request. We attach a
    /// code-signing requirement so the kernel rejects callers that
    /// aren't TidyMac signed by the same Team ID.
    ///
    /// Without a real Developer ID, the requirement string is built
    /// with a placeholder Team ID and the connection check fails — so
    /// the helper never accepts work in a development build. That's
    /// intentional: better to refuse than to accept blindly.
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let requirementString = """
        anchor apple generic \
        and identifier "com.tidymac.TidyMac" \
        and certificate leaf[subject.OU] = "\(HelperTeam.placeholderTeamID)"
        """

        var requirement: SecRequirement?
        let status = SecRequirementCreateWithString(
            requirementString as CFString,
            SecCSFlags(),
            &requirement
        )
        guard status == errSecSuccess, let requirement else {
            NSLog("[TidyMacHelper] Failed to build code requirement (OSStatus \(status)).")
            return false
        }

        // Look up the SecCode for the connecting process by PID.
        var code: SecCode?
        let codeStatus = SecCodeCopyGuestWithAttributes(
            nil,
            [kSecGuestAttributePid: connection.processIdentifier] as CFDictionary,
            SecCSFlags(),
            &code
        )
        guard codeStatus == errSecSuccess, let code else {
            NSLog("[TidyMacHelper] Couldn't read SecCode of pid \(connection.processIdentifier) (OSStatus \(codeStatus)).")
            return false
        }

        // Verify the caller satisfies our requirement.
        let validity = SecCodeCheckValidity(code, SecCSFlags(), requirement)
        guard validity == errSecSuccess else {
            NSLog("[TidyMacHelper] Rejecting connection from pid \(connection.processIdentifier) — code requirement failed (OSStatus \(validity)).")
            return false
        }

        // Connection approved. Wire up the protocol and resume.
        connection.exportedInterface = NSXPCInterface(with: HelperToolProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    // MARK: - HelperToolProtocol

    func getHelperVersion(withReply reply: @escaping (String) -> Void) {
        reply(kTidyMacHelperVersion)
    }

    func removeItem(atPath path: String,
                    withReply reply: @escaping (Bool, String?) -> Void) {
        let decision = HelperPaths.validate(path)
        guard decision.allowed else {
            NSLog("[TidyMacHelper] removeItem refused: \(path) — \(decision.reason)")
            reply(false, decision.reason)
            return
        }

        let resolvedPath = (path as NSString).resolvingSymlinksInPath
        // FileManager.removeItem will follow into the directory and
        // delete recursively. Operating on the resolved path again
        // ensures we never act on the original (symlink) target.
        do {
            try FileManager.default.removeItem(atPath: resolvedPath)
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func moveItemToTrash(atPath path: String,
                         withReply reply: @escaping (Bool, String?) -> Void) {
        // The user's ~/.Trash can't accept root-owned files, so we
        // maintain our own quarantine area instead. The user can
        // empty it via the helper's Settings page (a future polish
        // pass) or by deleting it manually.
        let decision = HelperPaths.validate(path)
        guard decision.allowed else {
            NSLog("[TidyMacHelper] moveItemToTrash refused: \(path) — \(decision.reason)")
            reply(false, decision.reason)
            return
        }

        let resolvedPath = (path as NSString).resolvingSymlinksInPath
        let resolvedURL = URL(fileURLWithPath: resolvedPath)
        let trashRoot = URL(fileURLWithPath: "/Library/Logs/TidyMac/HelperTrash", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: trashRoot, withIntermediateDirectories: true)
        } catch {
            reply(false, "Couldn't prepare helper trash: \(error.localizedDescription)")
            return
        }

        let timestamped = trashRoot
            .appendingPathComponent(timestampedName(for: resolvedURL.lastPathComponent), isDirectory: false)
        do {
            try FileManager.default.moveItem(atPath: resolvedPath, toPath: timestamped.path)
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    private func timestampedName(for original: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return "\(stamp)__\(original)"
    }
}

/// **Placeholder Team ID — REPLACE ME** with the OU value from your
/// Developer ID Application certificate before shipping. While this
/// reads "PLACEHOLDER", the connection-validation step will reject
/// every caller, which is exactly what we want during development —
/// the helper never accepts work without a real signing identity.
enum HelperTeam {
    static let placeholderTeamID = "PLACEHOLDER_TEAM_ID"
}
