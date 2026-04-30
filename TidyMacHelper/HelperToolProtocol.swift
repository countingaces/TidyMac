import Foundation

/// XPC interface between the main TidyMac app and the privileged helper.
/// `@objc` is mandatory — XPC's NSXPCInterface requires Objective-C
/// runtime visibility on protocols and their methods.
///
/// **Design rule:** every method here is a potential attack surface.
/// Keep the API as small as possible, validate every parameter inside
/// the helper, and return a (Bool, String?) tuple so the caller always
/// learns *why* an operation failed without the helper having to
/// throw across the XPC boundary.
@objc public protocol HelperToolProtocol {
    /// Permanently delete a file or directory. Use only for items
    /// outside the user's Trash (e.g., root-owned cache directories).
    func removeItem(atPath path: String,
                    withReply reply: @escaping (Bool, String?) -> Void)

    /// Move a file/directory to a Trash folder. The helper writes to
    /// `/Library/Logs/Tidymac/Trash/` since the user's `~/.Trash`
    /// can't accept root-owned files anyway.
    func moveItemToTrash(atPath path: String,
                         withReply reply: @escaping (Bool, String?) -> Void)

    /// Returns the helper's bundle version. Used by the app on launch
    /// to detect an out-of-date helper that needs re-registering.
    func getHelperVersion(withReply reply: @escaping (String) -> Void)
}

/// Mach service name the helper exposes and the app connects to.
/// Same string is in `MachServices` of the helper's launchd plist.
public let kTidyMacHelperMachServiceName = "com.tidymac.TidyMacHelper"

/// Bundle identifier of the helper. Used for SMAppService.daemon
/// registration and for code-requirement strings.
public let kTidyMacHelperBundleIdentifier = "com.tidymac.TidyMacHelper"

/// Filename of the launchd plist that ships inside the app bundle at
/// `Contents/Library/LaunchDaemons/<this>`. SMAppService.daemon takes
/// this filename as its `plistName:` argument.
public let kTidyMacHelperPlistName = "com.tidymac.TidyMacHelper.plist"

/// Helper version string. Bump when the protocol changes or when the
/// allowlist shifts so the app can detect a stale installed copy and
/// re-register.
public let kTidyMacHelperVersion = "1.0"
