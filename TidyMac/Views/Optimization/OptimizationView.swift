import SwiftUI
import AppKit

struct OptimizationView: View {
    @StateObject private var viewModel = OptimizationViewModel()
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            switch viewModel.loadState {
            case .idle, .loading:
                LoadingView(theme: viewModel.theme)
            case .error(let message):
                ErrorView(message: message)
            case .loaded:
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if viewModel.loadState == .idle {
                await viewModel.load()
            }
        }
        .onChange(of: viewModel.loadState) { _, newState in
            if newState == .loaded {
                updateBadge()
                handlePendingActionIfReady()
            }
        }
        .onChange(of: viewModel.items.map(\.id)) { _, _ in
            // Recompute the badge whenever the item list mutates (toggle
            // an agent off, remove a broken one, etc.).
            updateBadge()
        }
        .onChange(of: appState.pendingAction) { _, _ in
            handlePendingActionIfReady()
        }
        .alert(
            "Optimization",
            isPresented: Binding(
                get: { viewModel.alertMessage != nil },
                set: { if !$0 { viewModel.alertMessage = nil } }
            ),
            presenting: viewModel.alertMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { msg in
            Text(msg)
        }
    }

    private func updateBadge() {
        let issues = viewModel.brokenAgentCount
        appState.sidebarBadges[.optimization] = issues > 0
            ? "\(issues) issue\(issues == 1 ? "" : "s")"
            : nil
        appState.lastScanDates[.optimization] = Date()
    }

    /// Handle a pending action posted from the menu bar. Only fires once
    /// the scan has finished — otherwise we'd try to disable agents we
    /// haven't loaded yet.
    private func handlePendingActionIfReady() {
        guard appState.pendingAction == .disableNonEssentialAgents,
              viewModel.loadState == .loaded else { return }
        viewModel.disableAllNonEssential()
        appState.pendingAction = nil
    }

    private var content: some View {
        HStack(spacing: 0) {
            CategoryList(viewModel: viewModel)
                .frame(width: 220)
            Divider()
            DetailPane(viewModel: viewModel)
                .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Category list

private struct CategoryList: View {
    @ObservedObject var viewModel: OptimizationViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("OPTIMIZATION")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

            ForEach(StartupItem.Category.allCases) { category in
                CategoryRow(
                    category: category,
                    count: viewModel.count(in: category),
                    issueCount: issueCount(for: category),
                    isSelected: viewModel.selectedCategory == category,
                    theme: viewModel.theme
                ) {
                    viewModel.selectedCategory = category
                }
            }
            .padding(.horizontal, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.02))
    }

    private func issueCount(for category: StartupItem.Category) -> Int {
        viewModel.items(in: category).filter { $0.isIssue }.count
    }
}

private struct CategoryRow: View {
    let category: StartupItem.Category
    let count: Int
    let issueCount: Int
    let isSelected: Bool
    let theme: ColorTheme
    let onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: category.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(Color.secondary))
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(category.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    Text("\(count) item\(count == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if issueCount > 0 {
                    Text("\(issueCount)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.red.opacity(0.85)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var background: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.primary.opacity(0.15))
        } else if isHovered {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        } else {
            Color.clear
        }
    }
}

// MARK: - Detail pane

private struct DetailPane: View {
    @ObservedObject var viewModel: OptimizationViewModel

    var body: some View {
        let items = viewModel.items(in: viewModel.selectedCategory)
        VStack(spacing: 0) {
            Header(category: viewModel.selectedCategory, count: items.count, viewModel: viewModel)
            Divider()
            if items.isEmpty {
                EmptyState(category: viewModel.selectedCategory)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(items) { item in
                            ItemRow(item: item, viewModel: viewModel)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                }
            }
        }
    }
}

private struct Header: View {
    let category: StartupItem.Category
    let count: Int
    @ObservedObject var viewModel: OptimizationViewModel

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                    .font(.system(size: 16, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if category == .heavyConsumers {
                Button {
                    Task { await viewModel.refreshHeavyConsumers() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh process list")
            }

            if category == .launchAgents && viewModel.brokenAgentCount > 0 {
                Button("Remove all broken") {
                    viewModel.removeAllBroken()
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        switch category {
        case .loginItems:
            return "Apps set to open at login"
        case .launchAgents:
            return "Background helpers managed by launchd"
        case .heavyConsumers:
            return "Live snapshot of CPU and memory usage"
        }
    }
}

private struct EmptyState: View {
    let category: StartupItem.Category
    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: category.icon)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Nothing to show here")
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var detail: String {
        switch category {
        case .loginItems:
            return "Login items registered through System Settings → General → Login Items aren't listed here. Apps that auto-launch typically install a Launch Agent — check that tab."
        case .launchAgents:
            return "No third-party Launch Agents found in ~/Library/LaunchAgents or /Library/LaunchAgents."
        case .heavyConsumers:
            return "Couldn't read process list."
        }
    }
}

// MARK: - Item row

private struct ItemRow: View {
    let item: StartupItem
    @ObservedObject var viewModel: OptimizationViewModel

    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            iconView
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    StatusBadge(item: item)
                    if item.requiresAdmin {
                        Text("Admin required")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.4)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.14)))
                    }
                }

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let exe = item.executablePath {
                    Text(exe.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if item.isExecutableMissing {
                    Text("The executable for this agent no longer exists. It can be safely removed.")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                } else if item.isParentAppMissing, let parent = item.parentAppBundleId {
                    Text("The parent app (\(parent)) is no longer installed. This agent can be removed.")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 8)

            if item.source == .runningProcess {
                MetricsView(item: item)
            } else {
                actionControls
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        )
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon = item.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "gearshape.2")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
        }
    }

    private var subtitle: String {
        var parts: [String] = [item.type.displayName]
        if item.runAtLoad { parts.append("Runs at login") }
        if item.keepAlive { parts.append("Auto-restarts") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var actionControls: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if item.isIssue && !item.requiresAdmin {
                Button("Remove") {
                    viewModel.removeItem(id: item.id)
                }
                .controlSize(.small)
            } else {
                Toggle("", isOn: Binding(
                    get: { item.isEnabled },
                    set: { _ in viewModel.toggleItem(id: item.id) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .disabled(item.requiresAdmin)
            }
        }
    }
}

private struct StatusBadge: View {
    let item: StartupItem
    var body: some View {
        let (label, color): (String, Color) = {
            if item.isExecutableMissing { return ("Broken", .red) }
            if item.isParentAppMissing { return ("Orphaned", .orange) }
            if !item.isEnabled { return ("Disabled", .secondary) }
            return ("Enabled", .green)
        }()
        Text(label)
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

private struct MetricsView: View {
    let item: StartupItem

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let cpu = item.cpuPercent {
                Text("\(cpu, specifier: "%.1f")% CPU")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
            if let mem = item.memoryMB {
                Text("\(mem, specifier: "%.0f") MB")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 90, alignment: .trailing)
    }
}

// MARK: - Loading / Error

private struct LoadingView: View {
    let theme: ColorTheme
    @State private var rotation: Double = 0

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 6)
                    .frame(width: 80, height: 80)
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(theme.gradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 80, height: 80)
                    .rotationEffect(.degrees(rotation))
            }
            Text("Inspecting startup items…")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

private struct ErrorView: View {
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text("Couldn't load startup items")
                .font(.system(size: 16, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
