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
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                CategoryList(viewModel: viewModel)
                    .frame(width: 220)
                Divider()
                DetailPane(viewModel: viewModel)
                    .frame(maxWidth: .infinity)
            }
            if !viewModel.selectedRemovalIds.isEmpty {
                Divider()
                BottomBar(viewModel: viewModel)
            }
        }
    }
}

// MARK: - Bottom action bar

private struct BottomBar: View {
    @ObservedObject var viewModel: OptimizationViewModel
    @State private var showConfirm = false

    /// Mode of the bottom bar — derived from which category the selected
    /// items live in. Force Quit kills running processes; Remove deletes
    /// agent plists. Mixing them in one batch isn't possible because the
    /// view only shows one category at a time.
    private enum Mode {
        case removeAgents
        case forceQuitApps
    }

    private var mode: Mode {
        viewModel.selectedCategory == .hungApps ? .forceQuitApps : .removeAgents
    }

    var body: some View {
        let count = viewModel.selectedRemovalIds.count
        HStack(spacing: 12) {
            Button("Deselect All") {
                viewModel.deselectAll()
            }
            .buttonStyle(.link)

            Spacer()

            Text("\(count) item\(count == 1 ? "" : "s") selected")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Button {
                showConfirm = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: actionIcon)
                    Text(actionLabel)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.red.opacity(0.85))
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .confirmationDialog(
            confirmTitle(count: count),
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button(actionLabel, role: .destructive) {
                switch mode {
                case .removeAgents: viewModel.removeSelected()
                case .forceQuitApps: viewModel.forceQuitSelected()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    private var actionLabel: String {
        switch mode {
        case .removeAgents: return "Remove"
        case .forceQuitApps: return "Force Quit"
        }
    }

    private var actionIcon: String {
        switch mode {
        case .removeAgents: return "trash"
        case .forceQuitApps: return "xmark.octagon.fill"
        }
    }

    private func confirmTitle(count: Int) -> String {
        switch mode {
        case .removeAgents:
            return "Remove \(count) startup item\(count == 1 ? "" : "s")?"
        case .forceQuitApps:
            return "Force Quit \(count) application\(count == 1 ? "" : "s")?"
        }
    }

    private var confirmMessage: String {
        switch mode {
        case .removeAgents:
            return "This deletes the agent's plist file. User-owned plists go to the Trash; admin-owned ones are removed permanently after one password prompt."
        case .forceQuitApps:
            return "Force quitting kills the application immediately. Any unsaved work in those apps will be lost."
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

            if category == .hungApps {
                Button {
                    Task { await viewModel.refreshHungApps() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Re-check for unresponsive apps")
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
        case .hungApps:
            return "Apps that have stopped responding to events"
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
        case .hungApps:
            return "Nothing's hung. Your applications are all responding to events. Hit the refresh button to check again."
        }
    }
}

// MARK: - Item row

private struct ItemRow: View {
    let item: StartupItem
    @ObservedObject var viewModel: OptimizationViewModel

    @State private var isHovered = false

    var body: some View {
        let isSelectable = item.plistURL != nil || item.type == .hungApp
        HStack(alignment: .top, spacing: 12) {
            // Checkbox column. Skipped for items the bottom-bar action
            // can't actually act on.
            if isSelectable {
                Toggle("", isOn: Binding(
                    get: { viewModel.selectedRemovalIds.contains(item.id) },
                    set: { _ in viewModel.toggleSelection(id: item.id) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .padding(.top, 6)
            } else {
                Color.clear.frame(width: 16, height: 16)
            }

            iconView
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if item.requiresAdmin {
                        Text("Admin required")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.4)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.orange.opacity(0.14)))
                            .help("You'll be asked for your password when toggling or removing this item.")
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

            statusPill
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

    /// Status pill on the right edge that doubles as the enable/disable
    /// toggle. Green Enabled → click → red Disabled → click → green Enabled.
    /// Broken and Orphaned are non-clickable (no point "enabling" something
    /// whose executable is gone — the user removes it via the bottom bar).
    @ViewBuilder
    private var statusPill: some View {
        let isPending = viewModel.pendingItemIds.contains(item.id)
        if isPending {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: 80, alignment: .center)
        } else {
            StatusPill(item: item) {
                viewModel.toggleItem(id: item.id)
            }
        }
    }
}

private struct StatusPill: View {
    let item: StartupItem
    let onToggle: () -> Void
    @State private var isHovered = false

    private var canToggle: Bool {
        !item.isExecutableMissing && !item.isParentAppMissing && item.type != .hungApp
    }

    var body: some View {
        if canToggle {
            Button(action: onToggle) {
                pillBody
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .help(item.isEnabled ? "Click to disable" : "Click to enable")
        } else {
            pillBody
        }
    }

    private var pillBody: some View {
        let (label, color) = currentLabelAndColor
        return Text(label)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(minWidth: 80)
            .background(Capsule().fill(color.opacity(isHovered ? 0.24 : 0.16)))
            .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 0.5))
            .contentShape(Capsule())
    }

    private var currentLabelAndColor: (String, Color) {
        if item.type == .hungApp { return ("Not Responding", .red) }
        if item.isExecutableMissing { return ("Broken", .red) }
        if item.isParentAppMissing { return ("Orphaned", .orange) }
        if item.isEnabled { return ("Enabled", .green) }
        return ("Disabled", .red)
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
                Image(systemName: NavigationItem.optimization.symbolName)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(theme.gradient)
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
