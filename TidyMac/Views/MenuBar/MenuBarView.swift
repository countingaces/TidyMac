import SwiftUI
import AppKit
import ServiceManagement

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var monitor = SystemMonitor()
    @State private var launchAtLogin: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            healthSection
            Divider().padding(.vertical, 6)
            statsSection
            Divider().padding(.vertical, 6)
            actionsSection
            Divider().padding(.vertical, 6)
            footer
        }
        .padding(12)
        .frame(width: 280)
        .onAppear {
            monitor.start(every: 5)
            // SMAppService is the source of truth for the toggle; sync
            // once on appear without writing through AppStorage (which
            // can cause SwiftUI scene-update loops).
            if #available(macOS 13.0, *) {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
        .onDisappear {
            monitor.stop()
        }
    }

    // MARK: - Health

    @ViewBuilder
    private var healthSection: some View {
        if let score = appState.healthScore, let date = appState.lastSmartScanDate {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.10), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: CGFloat(score.overall) / 100)
                        .stroke(score.grade.color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(score.overall)")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(score.headline)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                    Text("Last scanned \(relativeDateString(date))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        } else {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18))
                    .foregroundStyle(NavigationItem.smartScan.theme.gradient)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No scan yet")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Run a Smart Scan to see your Mac's health.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }
        }
    }

    // MARK: - Stats

    @ViewBuilder
    private var statsSection: some View {
        VStack(spacing: 8) {
            StatBar(
                label: "CPU",
                value: monitor.cpuPercent,
                primary: String(format: "%.0f%%", monitor.cpuPercent * 100),
                tint: barTint(for: monitor.cpuPercent, redAbove: 0.85)
            )
            StatBar(
                label: "Memory",
                value: monitor.memoryUsedPercent,
                primary: monitor.memoryTotalBytes > 0
                    ? "\(ByteCountFormatter.string(fromByteCount: monitor.memoryUsedBytes, countStyle: .memory)) / \(ByteCountFormatter.string(fromByteCount: monitor.memoryTotalBytes, countStyle: .memory))"
                    : "—",
                tint: barTint(for: monitor.memoryUsedPercent, redAbove: 0.90)
            )
            StatBar(
                label: "Disk",
                value: 1 - monitor.diskFreePercent,
                primary: monitor.diskTotalBytes > 0
                    ? "\(ByteCountFormatter.string(fromByteCount: monitor.diskFreeBytes, countStyle: .file)) free"
                    : "—",
                tint: monitor.diskFreePercent < 0.10 ? .red : NavigationItem.smartScan.theme.primary
            )
        }
    }

    private func barTint(for value: Double, redAbove threshold: Double) -> Color {
        value > threshold ? .red : NavigationItem.smartScan.theme.primary
    }

    // MARK: - Actions

    @ViewBuilder
    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ActionRow(label: "Run Smart Scan", icon: "sparkles") {
                showMainWindow()
                appState.selection = .smartScan
                appState.pendingAction = .runSmartScan
            }
            ActionRow(label: "Open TidyMac", icon: "macwindow") {
                showMainWindow()
            }
            Toggle(isOn: Binding(
                get: { launchAtLogin },
                set: { newValue in
                    launchAtLogin = newValue
                    setLaunchAtLogin(newValue)
                }
            )) {
                HStack(spacing: 8) {
                    Image(systemName: "power")
                        .frame(width: 16)
                    Text("Launch at login")
                }
                .font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
        }
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // Find the main app window and bring it forward. If somehow there
        // isn't one (user closed everything), the dock icon click handler
        // in AppDelegate will re-spawn the WindowGroup's window.
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        Button {
            NSApp.terminate(nil)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "power.circle")
                    .frame(width: 16)
                Text("Quit TidyMac")
                Spacer()
                Text("⌘Q")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    // MARK: - SMAppService bridge

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Re-sync from system in case the call failed but flipped state
            // anyway (e.g. user-not-allowed).
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - StatBar

private struct StatBar: View {
    let label: String
    let value: Double
    let primary: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(tint)
                        .frame(width: geo.size.width * CGFloat(min(max(value, 0), 1)))
                }
            }
            .frame(height: 6)

            Text(primary)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
                .lineLimit(1)
        }
    }
}

private struct ActionRow: View {
    let label: String
    let icon: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                Text(label)
                Spacer()
            }
            .font(.system(size: 12))
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
