import SwiftUI

struct SpaceLensScanningView: View {
    @ObservedObject var viewModel: SpaceLensViewModel
    let progress: SpaceLensViewModel.ScanProgress

    @State private var rotation: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            spinner
                .padding(.bottom, 24)

            VStack(spacing: 8) {
                Text("Scanning…")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))

                Text(displayPath)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 540)

                Text(formattedCount)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ColorTheme.storage.primary)
                    .monospacedDigit()
                    .padding(.top, 6)
            }

            Spacer()

            Button(action: { viewModel.stopScan() }) {
                Text("Stop")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 130, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.red.opacity(0.88))
                    )
                    .shadow(color: .red.opacity(0.25), radius: 8, x: 0, y: 3)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var spinner: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 6)
                .frame(width: 96, height: 96)

            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(
                    ColorTheme.storage.gradient,
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .frame(width: 96, height: 96)
                .rotationEffect(.degrees(rotation))
                .onAppear {
                    withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                        rotation = 360
                    }
                }

            Image(systemName: "circle.grid.2x2.fill")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(ColorTheme.storage.gradient)
        }
    }

    private var formattedCount: String {
        let count = progress.filesScanned
        let noun = count == 1 ? "file" : "files"
        return "\(count.formatted()) \(noun) scanned"
    }

    private var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if progress.currentDirectory.hasPrefix(home) {
            return "~" + progress.currentDirectory.dropFirst(home.count)
        }
        return progress.currentDirectory
    }
}
