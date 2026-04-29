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

    /// One-shot triggers fired by menu bar commands. Modules observe via
    /// `.onChange(of: appState.pendingAction)` and clear the value after
    /// handling it. Using a value-typed enum (rather than NotificationCenter)
    /// keeps menu wiring out of the global notification namespace.
    @Published var pendingAction: PendingAction?

    enum PendingAction: Equatable {
        case disableNonEssentialAgents
        case runMaintenanceTasks
    }
}
