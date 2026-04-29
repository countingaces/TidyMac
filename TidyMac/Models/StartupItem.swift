import Foundation
import AppKit

/// One thing that runs at login or in the background. Can be a Login Item
/// (an app set to "Open at Login"), a Launch Agent (a launchd-managed
/// background helper), or a live process (a current heavy CPU/memory
/// consumer). Different sources, same row in the UI.
struct StartupItem: Identifiable, Hashable {
    let id: String
    let name: String
    let type: StartupItemType
    let source: StartupItemSource
    let executablePath: URL?
    let parentAppBundleId: String?
    let icon: NSImage?
    let isEnabled: Bool
    let isExecutableMissing: Bool
    let isParentAppMissing: Bool
    let keepAlive: Bool
    let runAtLoad: Bool
    let requiresAdmin: Bool

    /// Plist URL for Launch Agent items. Required when removing.
    let plistURL: URL?

    /// Live-process metrics for Heavy Consumers. Nil for everything else.
    let cpuPercent: Double?
    let memoryMB: Double?

    enum StartupItemType: String {
        case loginItem
        case backgroundAgent
        case scheduledTask
        case heavyConsumer

        var displayName: String {
            switch self {
            case .loginItem: return "Login Item"
            case .backgroundAgent: return "Background Agent"
            case .scheduledTask: return "Scheduled Task"
            case .heavyConsumer: return "Process"
            }
        }
    }

    enum StartupItemSource: String {
        case userLaunchAgent
        case systemLaunchAgent
        case systemLaunchDaemon
        case loginItemSMAppService
        case loginItemLegacy
        case runningProcess
    }

    enum Category: String, CaseIterable, Identifiable {
        case loginItems
        case launchAgents
        case heavyConsumers

        var id: String { rawValue }

        var title: String {
            switch self {
            case .loginItems: return "Login Items"
            case .launchAgents: return "Launch Agents"
            case .heavyConsumers: return "Heavy Consumers"
            }
        }

        var icon: String {
            switch self {
            case .loginItems: return "person.crop.circle.badge.clock"
            case .launchAgents: return "gearshape.2"
            case .heavyConsumers: return "speedometer"
            }
        }
    }

    /// Items that are flagged for the sidebar badge. A broken or orphaned
    /// agent is always actionable — its plist exists but the program doesn't,
    /// so the user almost certainly wants it gone.
    var isIssue: Bool { isExecutableMissing || isParentAppMissing }
}

extension StartupItem {
    static func category(for source: StartupItemSource, type: StartupItemType) -> Category {
        if type == .heavyConsumer { return .heavyConsumers }
        switch source {
        case .loginItemSMAppService, .loginItemLegacy:
            return .loginItems
        case .userLaunchAgent, .systemLaunchAgent, .systemLaunchDaemon, .runningProcess:
            return .launchAgents
        }
    }
}
