import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = AppViewModel()

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(selection: $viewModel.selection)
                .frame(width: 200)
                .frame(maxHeight: .infinity)

            Divider()

            mainContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    viewModel.selection.theme.backgroundGradient
                        .ignoresSafeArea()
                )
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        switch viewModel.selection {
        case .spaceLens:
            SpaceLensView()
        default:
            PlaceholderView(item: viewModel.selection)
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 1000, height: 650)
}
