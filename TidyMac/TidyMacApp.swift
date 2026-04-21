import SwiftUI

@main
struct TidyMacApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(
                    minWidth: 800,
                    idealWidth: 1000,
                    maxWidth: .infinity,
                    minHeight: 500,
                    idealHeight: 650,
                    maxHeight: .infinity
                )
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1000, height: 650)
    }
}
