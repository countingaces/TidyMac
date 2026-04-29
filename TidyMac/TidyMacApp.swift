import SwiftUI

@main
struct TidyMacApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
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
        .commands {
            CommandMenu("Tools") {
                Button("Disable All Non-Essential Launch Agents") {
                    appState.selection = .optimization
                    appState.pendingAction = .disableNonEssentialAgents
                }
                .keyboardShortcut("D", modifiers: [.command, .shift])

                Button("Run Maintenance") {
                    appState.selection = .maintenance
                    appState.pendingAction = .runMaintenanceTasks
                }
                .keyboardShortcut("R", modifiers: [.command, .shift])
            }
        }
    }
}
