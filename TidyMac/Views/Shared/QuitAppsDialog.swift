import SwiftUI
import AppKit

struct QuitAppsDialog: View {
    let apps: [NSRunningApplication]
    let theme: ColorTheme
    let onQuit: (NSRunningApplication) -> Void
    let onQuitAll: () -> Void
    let onIgnore: () -> Void
    let onCancel: () -> Void

    @State private var quittedIds: Set<pid_t> = []

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(SafetyLevel.cautious.color)

                Text("Some applications should be quit")
                    .font(.system(size: 18, weight: .semibold))
                    .multilineTextAlignment(.center)

                Text("Please quit the following applications to clean all of their related items:")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .padding(.top, 24)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(apps, id: \.processIdentifier) { app in
                        AppRow(
                            app: app,
                            isQuitted: quittedIds.contains(app.processIdentifier),
                            onQuit: {
                                onQuit(app)
                                quittedIds.insert(app.processIdentifier)
                            }
                        )
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 240)

            Divider()

            HStack(spacing: 8) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Ignore", action: onIgnore)

                Button("Quit All") {
                    for app in apps {
                        quittedIds.insert(app.processIdentifier)
                    }
                    onQuitAll()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 480)
    }
}

private struct AppRow: View {
    let app: NSRunningApplication
    let isQuitted: Bool
    let onQuit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.1))
                    .frame(width: 36, height: 36)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(app.localizedName ?? app.bundleIdentifier ?? "Unknown")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if let bundleId = app.bundleIdentifier {
                    Text(bundleId)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            if isQuitted {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Quitting…")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SafetyLevel.safe.color)
            } else {
                Button("Quit", action: onQuit)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}
