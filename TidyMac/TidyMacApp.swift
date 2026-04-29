import SwiftUI
import AppKit

@main
struct TidyMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        // Single-instance Window (not WindowGroup) so closing the window
        // hides it instead of tearing down the SwiftUI content. With
        // WindowGroup, closing destroys the view tree, and subsequent
        // MenuBarExtra popover opens beachball trying to reconcile a
        // partially-dead scene graph.
        Window("TidyMac", id: "main") {
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

                Divider()

                Button("Run Smart Scan") {
                    appState.selection = .smartScan
                    appState.pendingAction = .runSmartScan
                }
                .keyboardShortcut("S", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra("TidyMac", systemImage: "sparkles") {
            MenuBarView()
                .environmentObject(appState)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Lets TidyMac keep running in the menu bar after the user closes the
/// main window — without this, closing the window quits the app and
/// the menu bar icon vanishes with it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Called when the user clicks the dock icon. Re-show whichever
    /// window we have, or open a new one if all were closed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            for window in sender.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                return true
            }
        }
        return true
    }
}
