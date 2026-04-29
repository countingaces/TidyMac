import Foundation
import AppKit

enum FullDiskAccessChecker {
    private static let probePath = "/Library/Application Support/com.apple.TCC/TCC.db"

    static var isGranted: Bool {
        let fd = open(probePath, O_RDONLY)
        guard fd >= 0 else { return false }
        close(fd)
        return true
    }

    static func openSystemSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
