import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    @Published var selection: NavigationItem = .smartScan
}
