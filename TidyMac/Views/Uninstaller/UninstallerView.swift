import SwiftUI
import AppKit

struct UninstallerView: View {
    @StateObject private var viewModel = UninstallerViewModel()
    @EnvironmentObject private var appState: AppState
    @State private var showConfirmation = false
    @State private var detailAppId: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            switch viewModel.cleaningPhase {
            case .inProgress(let progress):
                CleaningProgressView(
                    progress: progress,
                    theme: viewModel.moduleInfo.colorTheme,
                    onStop: { viewModel.cancelCleaning() }
                )
            case .finished(let result):
                CleaningCompleteView(
                    result: result,
                    theme: viewModel.moduleInfo.colorTheme,
                    onStartOver: { viewModel.dismissCompletion() }
                )
            case .idle, .awaitingQuitDecision:
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if viewModel.loadState == .idle {
                await viewModel.loadApps()
            }
        }
        .onChange(of: viewModel.loadState) { _, newState in
            if newState == .loaded {
                appState.sidebarBadges[.uninstaller] = "\(viewModel.apps.count) apps"
                appState.lastScanDates[.uninstaller] = Date()
            }
        }
        .sheet(item: Binding(
            get: { detailAppId.map { AppIdHandle(id: $0) } },
            set: { detailAppId = $0?.id }
        )) { handle in
            if let app = viewModel.apps.first(where: { $0.id == handle.id }) {
                AppDetailSheet(viewModel: viewModel, app: app, onDismiss: { detailAppId = nil })
            }
        }
        .sheet(isPresented: quitSheetBinding) {
            QuitAppsDialog(
                apps: viewModel.runningAppsToQuit,
                theme: viewModel.moduleInfo.colorTheme,
                onQuit: { viewModel.quitApp($0) },
                onQuitAll: { viewModel.quitAllAndContinue() },
                onIgnore: { viewModel.ignoreAndContinue() },
                onCancel: { viewModel.cancelPreflight() }
            )
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move \(humanReadableSize(viewModel.selectedTotalSize)) to Trash", role: .destructive) {
                viewModel.requestUninstall()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
        .alert(
            "Uninstaller",
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
        // Cmd+F focuses the search field. Hidden button so keyboardShortcut
        // is wired into the view hierarchy without showing UI.
        .background {
            Button("Focus Search") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadState {
        case .idle, .loading:
            LoadingView(theme: viewModel.moduleInfo.colorTheme)
        case .error(let message):
            ErrorView(message: message)
        case .loaded:
            VStack(spacing: 0) {
                Toolbar(viewModel: viewModel, searchFocused: $searchFocused)
                Divider()
                AppList(
                    viewModel: viewModel,
                    onShowDetail: { detailAppId = $0 }
                )
                Divider()
                BottomBar(viewModel: viewModel) { showConfirmation = true }
            }
        }
    }

    // MARK: -

    private var confirmationTitle: String {
        let count = viewModel.selectedApps.count
        return "Uninstall \(count) app\(count == 1 ? "" : "s")?"
    }

    private var confirmationMessage: String {
        let count = viewModel.selectedApps.count
        let names = viewModel.selectedApps.prefix(3).map { $0.name }.joined(separator: ", ")
        let suffix = count > 3 ? " and \(count - 3) more" : ""
        return "Will move \(names)\(suffix) and their selected leftover files to the Trash. You can recover them from the Trash if needed."
    }

    private var quitSheetBinding: Binding<Bool> {
        Binding(
            get: {
                if case .awaitingQuitDecision = viewModel.cleaningPhase { return true }
                return false
            },
            set: { newValue in
                if !newValue { viewModel.cancelPreflight() }
            }
        )
    }
}

// Identifiable wrapper around the focused app id so .sheet(item:) can drive
// the detail sheet from a String.
private struct AppIdHandle: Identifiable {
    let id: String
}

// MARK: - Loading state

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
                Image(systemName: NavigationItem.uninstaller.symbolName)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(theme.gradient)
            }
            Text("Discovering installed apps…")
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
            Text("Couldn't load apps")
                .font(.system(size: 16, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Toolbar

private struct Toolbar: View {
    @ObservedObject var viewModel: UninstallerViewModel
    var searchFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search apps", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused(searchFocused)
                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 12)
                Picker("Sort", selection: $viewModel.sortMode) {
                    ForEach(UninstallerViewModel.SortMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 140)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )

            HStack(spacing: 6) {
                ForEach(UninstallerViewModel.FilterMode.allCases) { mode in
                    FilterPill(
                        label: mode.label,
                        isSelected: viewModel.filterMode == mode,
                        theme: viewModel.moduleInfo.colorTheme
                    ) {
                        viewModel.filterMode = mode
                    }
                }
                Spacer()
                Text("\(viewModel.visibleApps.count) of \(viewModel.apps.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

private struct FilterPill: View {
    let label: String
    let isSelected: Bool
    let theme: ColorTheme
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(background)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var background: Color {
        if isSelected { return theme.primary }
        if isHovered { return Color.primary.opacity(0.08) }
        return Color.primary.opacity(0.04)
    }
}

// MARK: - App list

private struct AppList: View {
    @ObservedObject var viewModel: UninstallerViewModel
    let onShowDetail: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                if !viewModel.orphans.isEmpty || viewModel.isDetectingOrphans {
                    OrphansSection(viewModel: viewModel)
                        .padding(.bottom, 6)
                }

                ForEach(viewModel.visibleApps) { app in
                    AppRow(
                        app: app,
                        viewModel: viewModel,
                        onShowDetail: { onShowDetail(app.id) }
                    )
                    .onAppear { viewModel.scanRemnants(for: app) }
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
        }
    }
}

// MARK: - Orphans

private struct OrphansSection: View {
    @ObservedObject var viewModel: UninstallerViewModel

    var body: some View {
        let theme = viewModel.moduleInfo.colorTheme
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if !viewModel.isDetectingOrphans && !viewModel.orphans.isEmpty {
                    CategoryCheckbox(
                        state: viewModel.orphansSelectionState,
                        theme: theme
                    ) {
                        viewModel.toggleAllOrphans()
                    }
                    .help("Select all orphaned files")
                } else {
                    // Spacer-equivalent so the row stays aligned during the
                    // initial detection pass.
                    Color.clear.frame(width: 20, height: 20)
                }

                Button {
                    viewModel.isOrphansSectionExpanded.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: viewModel.isOrphansSectionExpanded
                              ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)

                        Image(systemName: "questionmark.folder.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.gradient)
                            .frame(width: 24)

                        if viewModel.isDetectingOrphans {
                            Text("Looking for orphaned files…")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            ProgressView().controlSize(.small)
                        } else {
                            let summary = viewModel.orphansSummary
                            Text("\(summary.count) orphaned file\(summary.count == 1 ? "" : "s") from \(viewModel.orphans.count) removed app\(viewModel.orphans.count == 1 ? "" : "s")")
                                .font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text(humanReadableSize(summary.totalSize))
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .foregroundStyle(theme.primary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.primary.opacity(0.06))
            )

            if viewModel.isOrphansSectionExpanded {
                VStack(spacing: 1) {
                    ForEach(viewModel.orphans) { orphan in
                        OrphanRow(orphan: orphan, viewModel: viewModel)
                    }
                }
                .padding(.leading, 22)
            }
        }
    }
}

private struct OrphanRow: View {
    let orphan: OrphanDetector.Orphan
    @ObservedObject var viewModel: UninstallerViewModel
    @State private var isHovered = false

    var body: some View {
        let isSelected = viewModel.selectedOrphanIds.contains(orphan.id)
        let theme = viewModel.moduleInfo.colorTheme

        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { _ in viewModel.toggleOrphan(id: orphan.id) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(orphan.inferredName)
                    .font(.system(size: 12, weight: .semibold))
                Text(orphan.bundleId)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text("\(orphan.paths.count) location\(orphan.paths.count == 1 ? "" : "s")")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Text(humanReadableSize(orphan.totalSize))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? theme.primary.opacity(0.10)
                      : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(orphan.paths.map { $0.url.path }.joined(separator: "\n"))
    }
}

private struct AppRow: View {
    let app: AppInfo
    @ObservedObject var viewModel: UninstallerViewModel
    let onShowDetail: () -> Void

    @State private var isHovered = false

    var body: some View {
        let isSelected = viewModel.selectedAppIds.contains(app.id)
        let theme = viewModel.moduleInfo.colorTheme
        let eligibility = viewModel.eligibility(for: app)
        let isBlocked = eligibility.isBlocked

        HStack(spacing: 10) {
            if isBlocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .help(blockedReason(eligibility))
            } else {
                Toggle("", isOn: Binding(
                    get: { isSelected },
                    set: { _ in viewModel.toggleApp(id: app.id) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
            }

            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(app.version)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(lastUsedText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                sizeText
                CategoryBadge(category: app.category)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowBackground(theme: theme))
        )
        .contentShape(Rectangle())
        .onTapGesture { onShowDetail() }
        .onHover { isHovered = $0 }
    }

    private func rowBackground(theme: ColorTheme) -> Color {
        if viewModel.selectedAppIds.contains(app.id) { return theme.primary.opacity(0.10) }
        if isHovered { return Color.primary.opacity(0.04) }
        return .clear
    }

    private func blockedReason(_ eligibility: UninstallerViewModel.UninstallEligibility) -> String {
        if case .blocked(let reason) = eligibility { return reason }
        return "Protected"
    }

    private var lastUsedText: String {
        guard let date = app.lastUsedDate else { return "Never used" }
        let interval = Date().timeIntervalSince(date)
        let days = Int(interval / 86_400)
        if days <= 1 { return "Used today" }
        if days < 30 { return "Used \(days) days ago" }
        if days < 365 { return "Used \(days / 30) months ago" }
        return "Used over a year ago"
    }

    @ViewBuilder
    private var sizeText: some View {
        if viewModel.scanningAppIds.contains(app.id) {
            HStack(spacing: 5) {
                Text(humanReadableSize(app.bundleSize))
                    .font(.system(size: 11, design: .monospaced))
                ProgressView().controlSize(.mini).scaleEffect(0.7)
            }
        } else if let remnantSize = viewModel.remnantsSize(for: app.id), remnantSize > 0 {
            Text("\(humanReadableSize(app.bundleSize)) + \(humanReadableSize(remnantSize)) leftover")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        } else {
            Text(humanReadableSize(app.bundleSize))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

struct CategoryBadge: View {
    let category: AppCategory

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: category.icon)
                .font(.system(size: 8, weight: .semibold))
            Text(category.displayName)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.4)
        }
        .foregroundStyle(category.color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(category.color.opacity(0.14))
        )
    }
}

// MARK: - Bottom bar

private struct BottomBar: View {
    @ObservedObject var viewModel: UninstallerViewModel
    let onUninstall: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            if viewModel.hasUninstallSelection {
                Button("Deselect All") {
                    viewModel.selectedAppIds.removeAll()
                    viewModel.selectedOrphanIds.removeAll()
                }
                .buttonStyle(.link)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if !viewModel.hasUninstallSelection {
                    Text("Nothing selected")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Text(selectionDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(humanReadableSize(viewModel.selectedTotalSize))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(viewModel.moduleInfo.colorTheme.primary)
                        .monospacedDigit()
                }
            }

            Button(action: onUninstall) {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                    Text("Uninstall")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(canUninstall ? Color.white : Color.secondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(canUninstall ? viewModel.moduleInfo.colorTheme.primary : Color.primary.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .disabled(!canUninstall)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var canUninstall: Bool {
        viewModel.hasUninstallSelection
    }

    private var selectionDescription: String {
        let appCount = viewModel.selectedAppIds.count
        let orphanCount = viewModel.selectedOrphanIds.count
        var parts: [String] = []
        if appCount > 0 { parts.append("\(appCount) app\(appCount == 1 ? "" : "s")") }
        if orphanCount > 0 { parts.append("\(orphanCount) orphan group\(orphanCount == 1 ? "" : "s")") }
        return parts.joined(separator: " + ") + " selected"
    }
}
