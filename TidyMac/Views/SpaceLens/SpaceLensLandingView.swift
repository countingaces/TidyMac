import SwiftUI

struct SpaceLensLandingView: View {
    @ObservedObject var viewModel: SpaceLensViewModel
    @State private var showFullDiskAccessAlert = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 10) {
                Text("Space Lens")
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                Text("Get a visual size comparison of your folders and files")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 34)

            VStack(spacing: 18) {
                FeatureBullet(
                    icon: "chart.pie.fill",
                    title: "Instant size overview",
                    subtitle: "Browse your storage while seeing what takes the most space"
                )
                FeatureBullet(
                    icon: "bolt.fill",
                    title: "Quick decision-making",
                    subtitle: "Waste no time checking the size of what you're considering to remove"
                )
            }
            .frame(maxWidth: 440, alignment: .leading)
            .padding(.bottom, 32)

            if let disk = viewModel.diskInfo {
                LandingDiskRow(info: disk)
                    .frame(maxWidth: 440)
                    .padding(.bottom, 32)
            }

            ScanButton(action: scanStartupVolume)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .alert("Full Disk Access Required", isPresented: $showFullDiskAccessAlert) {
            Button("Open System Settings") {
                FullDiskAccessChecker.openSystemSettings()
            }
            Button("Scan Anyway", role: .destructive) {
                viewModel.startScan(url: URL(fileURLWithPath: "/"))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("To scan your Mac without permission prompts, grant TidyMac Full Disk Access in System Settings → Privacy & Security → Full Disk Access. After enabling it, relaunch TidyMac.\n\nWithout it, macOS will prompt for access to Photos, Apple Music, Desktop, Documents, Downloads, and iCloud.")
        }
    }

    private func scanStartupVolume() {
        if FullDiskAccessChecker.isGranted {
            viewModel.startScan(url: URL(fileURLWithPath: "/"))
        } else {
            showFullDiskAccessAlert = true
        }
    }
}

private struct FeatureBullet: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(ColorTheme.storage.primary.opacity(0.14))
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ColorTheme.storage.gradient)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct LandingDiskRow: View {
    let info: SpaceLensViewModel.DiskInfo

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(ColorTheme.storage.primary.opacity(0.14))
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(ColorTheme.storage.gradient)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(info.name): \(humanize(info.totalBytes))")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(humanize(info.usedBytes)) used")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                LandingCapacityBar(used: info.usedBytes, total: info.totalBytes)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    private func humanize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct LandingCapacityBar: View {
    let used: Int64
    let total: Int64

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(ColorTheme.storage.gradient)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 5)
    }

    private var fraction: CGFloat {
        guard total > 0 else { return 0 }
        return min(1, max(0, CGFloat(used) / CGFloat(total)))
    }
}

private struct ScanButton: View {
    let action: () -> Void
    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(ColorTheme.storage.gradient)
                    .frame(width: 96, height: 96)
                    .shadow(
                        color: ColorTheme.storage.primary.opacity(isHovered ? 0.45 : 0.28),
                        radius: isHovered ? 14 : 10,
                        x: 0,
                        y: 4
                    )
                    .scaleEffect(isPressed ? 0.96 : (isHovered ? 1.03 : 1.0))

                Text("Scan")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.16), value: isHovered)
        .animation(.easeInOut(duration: 0.12), value: isPressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}
