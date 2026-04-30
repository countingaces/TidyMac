import SwiftUI
import AppKit

struct SystemJunkView: View {
    @StateObject private var viewModel = SystemJunkViewModel()
    @EnvironmentObject private var appState: AppState
    @State private var showCleanConfirmation = false
    @State private var helperRequiredItems: [HelperRequiredSheet.DeferredItem] = []
    @Environment(\.openSettings) private var openSettings

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
                .onAppear { detectHelperRequired(in: result) }
            case .idle, .awaitingQuitDecision:
                ModuleView(
                    module: viewModel,
                    onCleanRequest: { showCleanConfirmation = true }
                ) { category in
                    JunkDetailPane(viewModel: viewModel, category: category)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Hand off from Smart Scan: if the user just ran a Smart Scan
            // and clicked Review Details, the orchestrator already has the
            // JunkItems in memory. Show them directly instead of asking
            // the user to scan again.
            if viewModel.scanState == .idle && !appState.smartScanJunkCategories.isEmpty {
                viewModel.populate(from: appState.smartScanJunkCategories)
                updateBadge(for: viewModel.scanState)
            }
        }
        .onChange(of: viewModel.scanState) { _, newState in
            updateBadge(for: newState)
        }
        .alert(
            "Clean",
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
        .confirmationDialog(
            confirmationTitle,
            isPresented: $showCleanConfirmation,
            titleVisibility: .visible
        ) {
            Button("Move \(humanReadableSize(viewModel.selectedSize)) to Trash", role: .destructive) {
                viewModel.requestClean()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
        .sheet(isPresented: Binding(
            get: { !helperRequiredItems.isEmpty },
            set: { if !$0 { helperRequiredItems = [] } }
        )) {
            HelperRequiredSheet(
                items: helperRequiredItems,
                onInstall: {
                    helperRequiredItems = []
                    openSettings()
                },
                onSkip: { helperRequiredItems = [] },
                onCancel: { helperRequiredItems = [] }
            )
        }
        .sheet(isPresented: quitSheetBinding) {
            QuitAppsDialog(
                apps: viewModel.runningAppsToQuit,
                theme: viewModel.moduleInfo.colorTheme,
                onQuit: { app in viewModel.quitApp(app) },
                onQuitAll: { viewModel.quitAllAndContinue() },
                onIgnore: { viewModel.ignoreAndContinue() },
                onCancel: { viewModel.cancelCleaningPreflight() }
            )
        }
    }

    // MARK: - Helpers

    private func updateBadge(for state: ScanState) {
        if case .complete = state {
            appState.sidebarBadges[.systemJunk] = humanReadableSize(viewModel.totalCleanableSize)
            appState.lastScanDates[.systemJunk] = Date()
        }
    }

    /// Sift through the cleaning result for items that failed because
    /// they need the privileged helper. If any are present, populate
    /// the deferred-items state which triggers the HelperRequiredSheet.
    private func detectHelperRequired(in result: CleaningService.CleaningResult) {
        let helperFails: [HelperRequiredSheet.DeferredItem] = result.failures.compactMap { url, error in
            guard case CleaningService.CleaningError.requiresHelper = error else { return nil }
            // Re-derive the size from the matching log entry so the
            // sheet shows accurate per-item numbers.
            let size = result.log.first(where: { $0.path == url })?.size ?? 0
            return HelperRequiredSheet.DeferredItem(path: url, size: size)
        }
        if !helperFails.isEmpty {
            helperRequiredItems = helperFails
        }
    }

    private var quitSheetBinding: Binding<Bool> {
        Binding(
            get: {
                if case .awaitingQuitDecision = viewModel.cleaningPhase { return true }
                return false
            },
            set: { newValue in
                if !newValue { viewModel.cancelCleaningPreflight() }
            }
        )
    }

    private var confirmationTitle: String {
        let count = viewModel.selectedItems.count
        return "Clean \(count) item\(count == 1 ? "" : "s")?"
    }

    private var confirmationMessage: String {
        let categories = Set(viewModel.selectedItems.map { $0.categoryId })
        let categoryNames = viewModel.results
            .filter { categories.contains($0.id) }
            .map { $0.title }
            .joined(separator: ", ")
        return "Items will be moved to the Trash from: \(categoryNames). You can recover them from the Trash if needed."
    }
}

// MARK: - Detail pane (System Junk specific)

private struct JunkDetailPane: View {
    @ObservedObject var viewModel: SystemJunkViewModel
    let category: ScanCategory<JunkItem>

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(category.title)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                    SafetyBadge(level: viewModel.safetyLevel(for: category))
                    Spacer()
                    Text(category.humanReadableSize)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(category.description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(viewModel.sortedItems(in: category)) { item in
                        JunkItemRow(
                            item: item,
                            isSelected: viewModel.selectedItemIds.contains(item.id),
                            theme: viewModel.moduleInfo.colorTheme,
                            onToggle: { viewModel.toggleItem(id: item.id) }
                        )
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            }
        }
    }
}

private struct JunkItemRow: View {
    let item: JunkItem
    let isSelected: Bool
    let theme: ColorTheme
    let onToggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { _ in onToggle() }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            JunkItemIcon(item: item, theme: theme)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.path.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text(item.humanReadableSize)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? theme.primary.opacity(0.10) : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.path])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path.path, forType: .string)
            }
        }
    }
}

private struct JunkItemIcon: View {
    let item: JunkItem
    let theme: ColorTheme

    var body: some View {
        if let nsImage = Self.icon(for: item) {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(theme.primary.opacity(0.12))
                Image(systemName: "doc.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.primary.opacity(0.7))
            }
            .frame(width: 28, height: 28)
        }
    }

    private static func icon(for item: JunkItem) -> NSImage? {
        if let bundleId = item.appBundleId,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }
        if FileManager.default.fileExists(atPath: item.path.path) {
            return NSWorkspace.shared.icon(forFile: item.path.path)
        }
        return nil
    }
}
