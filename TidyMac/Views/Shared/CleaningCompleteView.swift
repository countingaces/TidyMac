import SwiftUI
import AppKit

struct CleaningCompleteView: View {
    let result: CleaningService.CleaningResult
    let theme: ColorTheme
    let onStartOver: () -> Void

    @State private var checkmarkScale: CGFloat = 0
    @State private var showLog = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(theme.primary.opacity(0.14))
                    .frame(width: 120, height: 120)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64, weight: .medium))
                    .foregroundStyle(theme.gradient)
                    .scaleEffect(checkmarkScale)
            }
            .onAppear {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                    checkmarkScale = 1
                }
            }

            VStack(spacing: 6) {
                Text("\(humanReadableSize(result.totalSizeFreed)) Cleaned")
                    .font(.system(size: 32, weight: .semibold, design: .rounded))

                Text("\(result.itemsCleaned) item\(result.itemsCleaned == 1 ? "" : "s") moved to Trash")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                if !result.failures.isEmpty {
                    Text("\(result.failures.count) item\(result.failures.count == 1 ? "" : "s") couldn't be removed")
                        .font(.system(size: 12))
                        .foregroundStyle(SafetyLevel.cautious.color)
                        .padding(.top, 4)
                }
            }

            Spacer()

            HStack(spacing: 18) {
                Button {
                    showLog = true
                } label: {
                    Text("View Log")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.primary)
                }
                .buttonStyle(.plain)

                Button(action: onStartOver) {
                    Text("Start Over")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(theme.primary)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .sheet(isPresented: $showLog) {
            CleaningLogView(result: result, theme: theme, onDismiss: { showLog = false })
        }
    }

    private func humanReadableSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct CleaningLogView: View {
    let result: CleaningService.CleaningResult
    let theme: ColorTheme
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Cleaning Log")
                    .font(.headline)
                Spacer()
                if let url = result.logFileURL {
                    Button("Reveal Log File") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .buttonStyle(.link)
                }
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(result.log.enumerated()), id: \.offset) { _, entry in
                        LogRow(entry: entry, theme: theme)
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 720, height: 520)
    }
}

private struct LogRow: View {
    let entry: CleaningService.CleaningLogEntry
    let theme: ColorTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 11))
                    .foregroundStyle(iconColor)
                    .frame(width: 14)

                Text(entry.path.path)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let err = entry.error, entry.action == .failed {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(SafetyLevel.risky.color)
                    .padding(.leading, 22)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(entry.success ? Color.clear : Color.red.opacity(0.05))
        )
    }

    private var iconName: String {
        switch entry.action {
        case .movedToTrash: return "checkmark.circle.fill"
        case .skipped:      return "minus.circle"
        case .failed:       return "xmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch entry.action {
        case .movedToTrash: return SafetyLevel.safe.color
        case .skipped:      return Color.secondary
        case .failed:       return SafetyLevel.risky.color
        }
    }
}
