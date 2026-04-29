import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(selection: $appState.selection)
                .frame(width: 200)
                .frame(maxHeight: .infinity)

            Divider()

            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    appState.selection.theme.backgroundGradient
                        .ignoresSafeArea()
                )
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        switch appState.selection {
        case .spaceLens:
            SpaceLensView()
        case .systemJunk:
            SystemJunkView()
        case .uninstaller:
            UninstallerView()
        case .optimization:
            OptimizationView()
        case .maintenance:
            MaintenanceView()
        default:
            PlaceholderView(item: appState.selection)
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 1000, height: 650)
        .environmentObject(AppState())
}
