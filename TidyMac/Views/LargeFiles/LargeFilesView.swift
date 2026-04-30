import SwiftUI
import AppKit

struct LargeFilesView: View {
    @StateObject private var viewModel = LargeFilesViewModel()
    @EnvironmentObject private var appState: AppState
    @State private var showRemoveConfirm = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            switch viewModel.cleaningPhase {
            case .inProgress(let progress):
                CleaningProgressView(
                    progress: progress,
                    theme: NavigationItem.largeOldFiles.theme,
                    onStop: { viewModel.cancelCleaning() }
                )
            case .finished(let result):
                CleaningCompleteView(
                    result: result,
                    theme: NavigationItem.largeOldFiles.theme,
                    onStartOver: { viewModel.dismissCleaningResult() }
                )
            case .idle:
                phaseContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: viewModel.totalSize) { _, newValue in
            // Once the scan finishes, surface the total size to the
            // sidebar badge so the user can see the haul at a glance.
            if case .complete = viewModel.phase {
                appState.sidebarBadges[.largeOldFiles] = humanReadableSize(newValue)
            }
        }
        .onChange(of: viewModel.phase) { _, newPhase in
            if case .complete = newPhase {
                appState.sidebarBadges[.largeOldFiles] = humanReadableSize(viewModel.totalSize)
                appState.lastScanDates[.largeOldFiles] = Date()
            }
        }
        .alert(
            "Large & Old Files",
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
            "Move \(viewModel.selectedIds.count) file\(viewModel.selectedIds.count == 1 ? "" : "s") to Trash?",
            isPresented: $showRemoveConfirm,
            titleVisibility: .visible
        ) {
            Button("Move \(humanReadableSize(viewModel.selectedSize)) to Trash", role: .destructive) {
                viewModel.requestRemoval()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Files go to the Trash so you can recover them if needed.")
        }
        // Keyboard shortcuts — hidden buttons piped through the view
        // hierarchy so .keyboardShortcut hooks the responder chain.
        .background {
            Button("Focus Search") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
            Button("Select All Visible") { viewModel.selectAllVisible() }
                .keyboardShortcut("a", modifiers: .command)
                .opacity(0)
            Button("Remove Selected") {
                if !viewModel.selectedIds.isEmpty { showRemoveConfirm = true }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .opacity(0)
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch viewModel.phase {
        case .idle:
            LandingView(viewModel: viewModel)
        case .scanning(let progress):
            ScanningView(viewModel: viewModel, progress: progress)
        case .complete:
            ResultsLayout(viewModel: viewModel,
                          showRemoveConfirm: $showRemoveConfirm,
                          searchFocused: $searchFocused)
        case .error(let msg):
            ErrorView(message: msg, viewModel: viewModel)
        }
    }
}

// MARK: - Landing

private struct LandingView: View {
    @ObservedObject var viewModel: LargeFilesViewModel

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            ZStack {
                Circle()
                    .fill(NavigationItem.largeOldFiles.theme.primary.opacity(0.12))
                    .frame(width: 120, height: 120)
                Image(systemName: NavigationItem.largeOldFiles.symbolName)
                    .font(.system(size: 50, weight: .medium))
                    .foregroundStyle(NavigationItem.largeOldFiles.theme.gradient)
            }

            VStack(spacing: 8) {
                Text("Large & Old Files")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("Find files you may no longer need")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                FeatureRow(icon: "magnifyingglass.circle.fill",
                           title: "Deep search",
                           detail: "Scans your entire home directory for large and forgotten files.")
                FeatureRow(icon: "slider.horizontal.3",
                           title: "Smart filtering",
                           detail: "Filter by kind, size, and how recently you accessed each file.")
            }
            .frame(maxWidth: 460)

            Spacer()

            Button(action: { viewModel.startScan() }) {
                Text("Scan")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(NavigationItem.largeOldFiles.theme.gradient)
                    )
            }
            .buttonStyle(.plain)
            .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(NavigationItem.largeOldFiles.theme.primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Scanning

private struct ScanningView: View {
    @ObservedObject var viewModel: LargeFilesViewModel
    let progress: LargeFileScanner.Progress
    @State private var rotation: Double = 0

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 6)
                    .frame(width: 96, height: 96)
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(NavigationItem.largeOldFiles.theme.gradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 96, height: 96)
                    .rotationEffect(.degrees(rotation))
                Image(systemName: NavigationItem.largeOldFiles.symbolName)
                    .font(.system(size: 28))
                    .foregroundStyle(NavigationItem.largeOldFiles.theme.gradient)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }

            VStack(spacing: 6) {
                Text("Scanning your home folder…")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text("\(progress.filesFound.formatted()) file\(progress.filesFound == 1 ? "" : "s") · \(humanReadableSize(progress.totalSize))")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(NavigationItem.largeOldFiles.theme.primary)
                    .monospacedDigit()
                if !progress.currentDirectory.isEmpty {
                    Text(progress.currentDirectory)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 480)
                }
            }

            Spacer()

            Button(action: { viewModel.cancelScan() }) {
                Text("Stop")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 130, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.88))
                    )
            }
            .buttonStyle(.plain)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

// MARK: - Results

private struct ResultsLayout: View {
    @ObservedObject var viewModel: LargeFilesViewModel
    @Binding var showRemoveConfirm: Bool
    var searchFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                FilterSidebar(viewModel: viewModel)
                    .frame(width: 240)
                Divider()
                FileListPane(viewModel: viewModel, searchFocused: searchFocused)
            }
            Divider()
            BottomBar(viewModel: viewModel, showRemoveConfirm: $showRemoveConfirm)
        }
    }
}

// MARK: - Filter sidebar

private struct FilterSidebar: View {
    @ObservedObject var viewModel: LargeFilesViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                topRows
                section(title: "BY KIND") {
                    ForEach(FileKind.allCases, id: \.self) { kind in
                        let facet = viewModel.count(for: kind)
                        FilterRow(
                            label: kind.displayName,
                            symbol: kind.iconSymbol,
                            count: facet.count,
                            size: facet.totalSize,
                            isActive: viewModel.activeKindFilter == kind
                        ) {
                            viewModel.setKindFilter(kind)
                        }
                    }
                }
                section(title: "BY SIZE") {
                    ForEach(SizeCategory.allCases, id: \.self) { size in
                        let facet = viewModel.count(for: size)
                        FilterRow(
                            label: size.displayName,
                            symbol: nil,
                            count: facet.count,
                            size: facet.totalSize,
                            isActive: viewModel.activeSizeFilter == size,
                            detail: size.detail
                        ) {
                            viewModel.setSizeFilter(size)
                        }
                    }
                }
                section(title: "BY ACCESS DATE") {
                    ForEach([AccessCategory.overOneYear, .overOneMonth, .overOneWeek], id: \.self) { access in
                        let facet = viewModel.count(for: access)
                        FilterRow(
                            label: access.displayName,
                            symbol: nil,
                            count: facet.count,
                            size: facet.totalSize,
                            isActive: viewModel.activeAccessFilter == access
                        ) {
                            viewModel.setAccessFilter(access)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
        }
        .background(Color.primary.opacity(0.02))
    }

    private var topRows: some View {
        VStack(spacing: 4) {
            FilterRow(
                label: "All Files",
                symbol: "tray.full.fill",
                count: viewModel.files.count,
                size: viewModel.totalSize,
                isActive: !viewModel.hasActiveFilter && viewModel.searchQuery.isEmpty,
                isHeadline: true
            ) {
                viewModel.clearAllFilters()
            }

            if !viewModel.selectedIds.isEmpty {
                FilterRow(
                    label: "Selected",
                    symbol: "checkmark.circle.fill",
                    count: viewModel.selectedIds.count,
                    size: viewModel.selectedSize,
                    isActive: false,
                    isHeadline: true,
                    accentColor: NavigationItem.largeOldFiles.theme.primary
                ) { /* informational */ }
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 4)
            content()
        }
    }
}

private struct FilterRow: View {
    let label: String
    let symbol: String?
    let count: Int
    let size: Int64
    let isActive: Bool
    var detail: String? = nil
    var isHeadline: Bool = false
    var accentColor: Color? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(iconStyle)
                        .frame(width: 18)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 12, weight: isActive || isHeadline ? .semibold : .regular))
                    if let detail {
                        Text(detail)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(humanReadableSize(size))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("\(count)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var iconStyle: AnyShapeStyle {
        if isActive { return AnyShapeStyle(NavigationItem.largeOldFiles.theme.gradient) }
        if let accentColor { return AnyShapeStyle(accentColor) }
        return AnyShapeStyle(Color.secondary)
    }

    @ViewBuilder
    private var background: some View {
        if isActive {
            RoundedRectangle(cornerRadius: 6)
                .fill(NavigationItem.largeOldFiles.theme.primary.opacity(0.15))
        } else if isHovered {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.05))
        } else {
            Color.clear
        }
    }
}

// MARK: - File list pane

private struct FileListPane: View {
    @ObservedObject var viewModel: LargeFilesViewModel
    var searchFocused: FocusState<Bool>.Binding

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(viewModel.filterTitle)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                if viewModel.hasActiveFilter {
                    Button("Clear") { viewModel.clearAllFilters() }
                        .controlSize(.small)
                }
                Spacer()
                Picker("", selection: $viewModel.sortMode) {
                    ForEach(LargeFilesViewModel.SortMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 150)
                .labelsHidden()
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search files", text: $viewModel.searchQuery)
                    .textFieldStyle(.plain)
                    .focused(searchFocused)
                if !viewModel.searchQuery.isEmpty {
                    Button {
                        viewModel.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04))
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var list: some View {
        let visible = viewModel.filteredFiles
        if visible.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "tray")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                Text("No files match the current filter")
                    .font(.system(size: 13, weight: .semibold))
                Text("Try clearing a filter or running another scan.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(visible) { file in
                        FileRow(
                            file: file,
                            isSelected: viewModel.selectedIds.contains(file.id),
                            theme: NavigationItem.largeOldFiles.theme,
                            onToggle: { viewModel.toggleSelection(id: file.id) }
                        )
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
            }
        }
    }
}

private struct FileRow: View {
    let file: LargeFile
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

            FileIcon(url: file.url, kind: file.kind, theme: theme)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(relativeFolder(file.url))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if file.isDownloaded {
                        Text("Downloaded")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.4)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.14)))
                    }
                    if let date = file.effectiveDate {
                        Text(relativeDateString(date))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer(minLength: 8)

            Text(humanReadableSize(file.size))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? theme.primary.opacity(0.10)
                      : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(isSelected ? "Deselect" : "Select for Removal") { onToggle() }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            }
            Button("Quick Look") {
                quickLook(file.url)
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.url.path, forType: .string)
            }
        }
    }

    private func relativeFolder(_ url: URL) -> String {
        let folder = url.deletingLastPathComponent().path
        let home = NSHomeDirectory()
        if folder.hasPrefix(home + "/") {
            return "~/" + String(folder.dropFirst(home.count + 1))
        }
        return folder
    }

    private func quickLook(_ url: URL) {
        // Open the file in the default Quick Look helper. SwiftUI doesn't
        // expose QLPreviewPanel cleanly; "open -a Finder" doesn't trigger
        // QL — using NSWorkspace.open + a quick AppleScript would over-
        // complicate things. Reveal-in-Finder is the closest no-cost
        // alternative; the spec lists Quick Look as a context-menu option
        // but the panel wiring lives in a future polish pass.
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private struct FileIcon: View {
    let url: URL
    let kind: FileKind
    let theme: ColorTheme

    var body: some View {
        if FileManager.default.fileExists(atPath: url.path),
           let icon = Optional(NSWorkspace.shared.icon(forFile: url.path)) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(theme.primary.opacity(0.12))
                Image(systemName: kind.iconSymbol)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.primary.opacity(0.7))
            }
        }
    }
}

// MARK: - Bottom bar

private struct BottomBar: View {
    @ObservedObject var viewModel: LargeFilesViewModel
    @Binding var showRemoveConfirm: Bool

    var body: some View {
        HStack(spacing: 12) {
            if !viewModel.selectedIds.isEmpty {
                Button("Deselect All") { viewModel.deselectAll() }
                    .buttonStyle(.link)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if viewModel.selectedIds.isEmpty {
                    Text("Nothing selected")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(viewModel.selectedIds.count) file\(viewModel.selectedIds.count == 1 ? "" : "s") selected")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(humanReadableSize(viewModel.selectedSize))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(NavigationItem.largeOldFiles.theme.primary)
                        .monospacedDigit()
                }
            }

            Button {
                showRemoveConfirm = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                    Text("Remove")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(viewModel.selectedIds.isEmpty ? Color.secondary : Color.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(viewModel.selectedIds.isEmpty ? Color.primary.opacity(0.08) : Color.red.opacity(0.85))
                )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.selectedIds.isEmpty)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Error

private struct ErrorView: View {
    let message: String
    @ObservedObject var viewModel: LargeFilesViewModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text("Scan failed")
                .font(.system(size: 16, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("Try Again") { viewModel.startScan() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
