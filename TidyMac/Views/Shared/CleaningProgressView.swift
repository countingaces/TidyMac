import SwiftUI

struct CleaningProgressView: View {
    let progress: CleaningService.Progress
    let theme: ColorTheme
    let onStop: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 8)
                    .frame(width: 140, height: 140)

                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(theme.gradient, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 140, height: 140)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.2), value: fraction)

                VStack(spacing: 4) {
                    Text("\(Int(fraction * 100))%")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("\(progress.itemsCompleted) of \(progress.totalItems)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            VStack(spacing: 8) {
                Text("Cleaning…")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))

                Text(progress.currentItemName.isEmpty ? "Finishing up…" : progress.currentItemName)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 480)

                Text("\(humanReadableSize(progress.sizeFreedSoFar)) freed")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.primary)
                    .padding(.top, 4)
            }

            Spacer()

            Button(action: onStop) {
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

    private var fraction: CGFloat {
        guard progress.totalItems > 0 else { return 0 }
        return CGFloat(progress.itemsCompleted) / CGFloat(progress.totalItems)
    }

    private func humanReadableSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
