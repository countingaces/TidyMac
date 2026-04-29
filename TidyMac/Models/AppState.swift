import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var sidebarBadges: [NavigationItem: String] = [:]
    @Published var lastScanDates: [NavigationItem: Date] = [:]
}
