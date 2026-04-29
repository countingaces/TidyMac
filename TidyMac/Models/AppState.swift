import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var selection: NavigationItem = .smartScan
    @Published var sidebarBadges: [NavigationItem: String] = [:]
    @Published var lastScanDates: [NavigationItem: Date] = [:]
    @Published var healthScore: HealthScore?
    @Published var lastSmartScanDate: Date?
    @Published var smartScanResults: SmartScanResults?

    /// Handoff data from Smart Scan to the per-module pages. Set when
    /// Smart Scan completes; consumed (and not cleared — re-readable so
    /// the user can switch tabs and come back) by the destination
    /// module's view on appear, in lieu of triggering its own scan.
    @Published var smartScanJunkCategories: [ScanCategory<JunkItem>] = []
    @Published var smartScanOrphans: [OrphanDetector.Orphan] = []

    /// One-shot triggers fired by menu bar commands. Modules observe via
    /// `.onChange(of: appState.pendingAction)` and clear the value after
    /// handling it. Using a value-typed enum (rather than NotificationCenter)
    /// keeps menu wiring out of the global notification namespace.
    @Published var pendingAction: PendingAction?

    enum PendingAction: Equatable {
        case disableNonEssentialAgents
        case runMaintenanceTasks
        case runSmartScan
    }
}
