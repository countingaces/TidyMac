import SwiftUI

struct SpaceLensView: View {
    @StateObject private var viewModel = SpaceLensViewModel()

    var body: some View {
        Group {
            switch viewModel.scanState {
            case .landing:
                SpaceLensLandingView(viewModel: viewModel)
            case .scanning(let progress):
                SpaceLensScanningView(viewModel: viewModel, progress: progress)
            case .results:
                SpaceLensResultsView(viewModel: viewModel)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    SpaceLensView()
        .frame(width: 900, height: 650)
}
