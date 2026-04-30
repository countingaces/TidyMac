import Foundation

/// Shared between helper (enforced) and app (displayed in Settings UI
/// for transparency). The Settings disclosure that lists "Allowed
/// Locations" reads directly from this file — what the user sees is
/// exactly what the helper enforces.
public enum HelperPaths {

    /// **Allowlist** — only paths under one of these prefixes are
    /// candidates for deletion by the helper. Updating these values
    /// requires re-registering the helper (the installed copy keeps
    /// its compiled-in lists until SMAppService re-installs it).
    public static let allowedPrefixes: [String] = [
        "/Library/Caches/",
        "/Library/Logs/",
        "/Library/Updates/",
        "/Library/Developer/CoreSimulator/",
        "/var/log/",
        "/private/var/log/",
        "/tmp/",
        "/private/tmp/"
    ]

    /// **Denylist** — paths under any of these prefixes are NEVER
    /// deletable, even if they also match the allowlist. Checked
    /// before the allowlist (default deny, explicit allow, hard
    /// blocks override). When in doubt, refuse — fail-closed beats
    /// fail-open in security-critical code.
    public static let deniedPrefixes: [String] = [
        "/System/",
        "/usr/",
        "/bin/",
        "/sbin/",
        "/Applications/",
        "/Library/LaunchDaemons/",         // could disable system services
        "/Library/LaunchAgents/",           // could disable system agents
        "/Library/PrivilegedHelperTools/",  // could delete ourselves
        "/Library/SystemMigration/",
        "/Library/Frameworks/",
        "/Library/Extensions/",             // kernel/system extensions
        "/Library/Preferences/com.apple."   // any Apple-managed preferences
    ]

    /// Decision returned by the validator. The helper builds these
    /// and returns the `reason` to the app for surfacing in error
    /// messages without leaking implementation details.
    public struct Decision {
        public let allowed: Bool
        public let reason: String

        public init(allowed: Bool, reason: String) {
            self.allowed = allowed
            self.reason = reason
        }
    }

    /// Validate a path against the rules. **Resolves symlinks first**
    /// to defeat TOCTOU attacks where a symlink under an allowed
    /// prefix could redirect into a denied location. The single line
    /// `(path as NSString).resolvingSymlinksInPath` is the only thing
    /// preventing a malicious caller from asking us to "delete a file
    /// in /Library/Caches/" that's actually a symlink to a kernel.
    public static func validate(_ path: String) -> Decision {
        let resolved = (path as NSString).resolvingSymlinksInPath

        // Denylist FIRST — explicit blocks take priority over any allow.
        for denied in deniedPrefixes {
            if resolved.hasPrefix(denied) {
                return Decision(allowed: false,
                                reason: "Path is in a protected system location")
            }
        }

        // Then allowlist.
        for allowed in allowedPrefixes {
            if resolved.hasPrefix(allowed) {
                return Decision(allowed: true,
                                reason: "Path is in an approved cleanup location")
            }
        }

        return Decision(allowed: false,
                        reason: "Path is not in any approved cleanup location")
    }
}
