import SwiftUI
import AppKit

struct SystemJunkView: View {
    @StateObject private var viewModel = SystemJunkViewModel()
    @State private var showCleanConfirmation = false

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
                normalContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    @ViewBuilder
    private var normalContent: some View {
        switch viewModel.scanState {
        case .idle:
            LandingView(viewModel: viewModel)
        case .scanning(let progress):
            ScanningView(viewModel: viewModel, progress: progress)
        case .complete:
            ResultsView(viewModel: viewModel, showCleanConfirmation: $showCleanConfirmation)
        case .error(let message):
            ErrorView(viewModel: viewModel, message: message)
        }
    }

    private var quitSheetBinding: Binding<Bool> {
        Binding(
            get: {
                if case .awaitingQuitDecision = viewModel.cleaningPhase { return true }
                return false
            },
            set: { newValue in
                if !newValue {
                    viewModel.cancelCleaningPreflight()
                }
            }
        )
    }
}

// MARK: - Landing

private struct LandingView: View {
    @ObservedObject var viewModel: SystemJunkViewModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 10) {
                Text(viewModel.moduleInfo.title)
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                Text(viewModel.moduleInfo.description)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 34)

            VStack(spacing: 18) {
                FeatureBullet(
                    icon: "scope",
                    title: "Deep clean",
                    subtitle: "Removes caches, logs, and temporary files that accumulate over time",
                    theme: viewModel.moduleInfo.colorTheme
                )
                FeatureBullet(
                    icon: "wand.and.rays",
                    title: "Smart detection",
                    subtitle: "Identifies junk from specific apps like Xcode, browsers, and mail",
                    theme: viewModel.moduleInfo.colorTheme
                )
            }
            .frame(maxWidth: 460, alignment: .leading)
            .padding(.bottom, 36)

            ScanButton(theme: viewModel.moduleInfo.colorTheme) {
                viewModel.beginScan()
            }

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

private struct FeatureBullet: View {
    let icon: String
    let title: String
    let subtitle: String
    let theme: ColorTheme

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(theme.primary.opacity(0.14))
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.gradient)
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

private struct ScanButton: View {
    let theme: ColorTheme
    let action: () -> Void
    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(theme.gradient)
                    .frame(width: 96, height: 96)
                    .shadow(
                        color: theme.primary.opacity(isHovered ? 0.45 : 0.28),
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

// MARK: - Scanning

private struct ScanningView: View {
    @ObservedObject var viewModel: SystemJunkViewModel
    let progress: ScanProgress
    @State private var rotation: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            spinner
                .padding(.bottom, 24)

            VStack(spacing: 8) {
                Text(progress.currentActivity.isEmpty ? "Scanning…" : progress.currentActivity)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))

                Text("\(progress.itemsFound.formatted()) item\(progress.itemsFound == 1 ? "" : "s") · \(humanReadableSize(progress.sizeFound))")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(viewModel.moduleInfo.colorTheme.primary)
                    .monospacedDigit()
                    .padding(.top, 6)
            }

            Spacer()

            Button(action: { viewModel.cancelScan() }) {
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

    private var spinner: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 6)
                .frame(width: 96, height: 96)

            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(
                    viewModel.moduleInfo.colorTheme.gradient,
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .frame(width: 96, height: 96)
                .rotationEffect(.degrees(rotation))
                .onAppear {
                    withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                        rotation = 360
                    }
                }

            Image(systemName: viewModel.moduleInfo.icon)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(viewModel.moduleInfo.colorTheme.gradient)
        }
    }
}

// MARK: - Results (three-panel)

private struct ResultsView: View {
    @ObservedObject var viewModel: SystemJunkViewModel
    @Binding var showCleanConfirmation: Bool

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    CategoryListPanel(viewModel: viewModel)
                        .frame(width: max(280, geo.size.width * 0.36))

                    Divider()

                    CategoryDetailPanel(viewModel: viewModel)
                        .frame(maxWidth: .infinity)
                }
            }

            Divider()

            BottomActionBar(viewModel: viewModel, showCleanConfirmation: $showCleanConfirmation)
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

// MARK: - Category List Panel

private struct CategoryListPanel: View {
    @ObservedObject var viewModel: SystemJunkViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Header with deselect + sort toggle
            HStack(spacing: 12) {
                Button {
                    viewModel.deselectAll()
                } label: {
                    Text("Deselect All")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.link)
                .disabled(viewModel.selectedItemIds.isEmpty)

                Spacer()

                Picker("", selection: $viewModel.sortMode) {
                    Text("Size").tag(SystemJunkViewModel.SortMode.size)
                    Text("Name").tag(SystemJunkViewModel.SortMode.name)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(viewModel.sortedCategories) { category in
                        CategoryRow(
                            category: category,
                            isFocused: viewModel.selectedCategoryId == category.id,
                            selectionState: viewModel.selectionState(for: category),
                            safetyLevel: viewModel.safetyLevel(for: category),
                            theme: viewModel.moduleInfo.colorTheme,
                            onToggle: { viewModel.toggleCategory(id: category.id) },
                            onSelect: { viewModel.selectedCategoryId = category.id }
                        )
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            }
        }
    }
}

private struct CategoryRow: View {
    let category: ScanCategory<JunkItem>
    let isFocused: Bool
    let selectionState: SystemJunkViewModel.SelectionState
    let safetyLevel: SafetyLevel
    let theme: ColorTheme
    let onToggle: () -> Void
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            CategoryCheckbox(state: selectionState, theme: theme, action: onToggle)

            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.primary.opacity(0.14))
                Image(systemName: category.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.gradient)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(category.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if safetyLevel != .safe {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(safetyLevel.color)
                            .help(safetyLevel.description)
                    }
                }
                Text("\(category.itemCount) item\(category.itemCount == 1 ? "" : "s")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            Text(category.humanReadableSize)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(category.itemCount == 0 ? Color.secondary : Color.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(rowBackground)
        )
        .opacity(category.itemCount == 0 ? 0.55 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { isHovered = $0 }
    }

    private var rowBackground: Color {
        if isFocused { return theme.primary.opacity(0.14) }
        if isHovered { return Color.primary.opacity(0.05) }
        return Color.clear
    }
}

// MARK: - Detail Panel

private struct CategoryDetailPanel: View {
    @ObservedObject var viewModel: SystemJunkViewModel

    var body: some View {
        if let category = viewModel.selectedCategory {
            VStack(alignment: .leading, spacing: 0) {
                // Header
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

                // Items
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(viewModel.sortedItems(in: category)) { item in
                            ItemRow(
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
        } else {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("Select a category")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ItemRow: View {
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

            ItemIcon(item: item, theme: theme)

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

private struct ItemIcon: View {
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

private struct SafetyBadge: View {
    let level: SafetyLevel

    var body: some View {
        Text(level.shortLabel)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(level.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(level.color.opacity(0.14))
            )
            .overlay(
                Capsule().stroke(level.color.opacity(0.3), lineWidth: 0.5)
            )
    }
}

// MARK: - Bottom Action Bar

private struct BottomActionBar: View {
    @ObservedObject var viewModel: SystemJunkViewModel
    @Binding var showCleanConfirmation: Bool

    var body: some View {
        HStack(spacing: 14) {
            Button {
                viewModel.returnToIdle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.uturn.left")
                    Text("Rescan")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
            }
            .buttonStyle(.plain)

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if viewModel.selectedItems.isEmpty {
                    Text("Nothing selected")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(viewModel.selectedItems.count) item\(viewModel.selectedItems.count == 1 ? "" : "s") selected")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(humanReadableSize(viewModel.selectedSize))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(viewModel.moduleInfo.colorTheme.primary)
                        .monospacedDigit()
                }
            }

            Button(action: {
                showCleanConfirmation = true
            }) {
                HStack(spacing: 6) {
                    if viewModel.isCleaning {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "trash")
                    }
                    Text(viewModel.isCleaning ? "Cleaning…" : "Clean")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(cleanIsActive ? Color.white : Color.secondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(cleanIsActive
                              ? viewModel.moduleInfo.colorTheme.primary
                              : Color.primary.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .disabled(!cleanIsActive)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var cleanIsActive: Bool {
        !viewModel.selectedItems.isEmpty && !viewModel.isCleaning
    }
}

// MARK: - Helpers

private struct CategoryCheckbox: View {
    let state: SystemJunkViewModel.SelectionState
    let theme: ColorTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: iconName)
                .font(.system(size: 16))
                .foregroundStyle(state == .none ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(theme.gradient))
        }
        .buttonStyle(.plain)
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
    }

    private var iconName: String {
        switch state {
        case .none: return "square"
        case .partial: return "minus.square.fill"
        case .all: return "checkmark.square.fill"
        }
    }
}

// MARK: - Error

private struct ErrorView: View {
    @ObservedObject var viewModel: SystemJunkViewModel
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Scan failed")
                .font(.system(size: 18, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Try again") { viewModel.beginScan() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

// MARK: - File-private utility

private func humanReadableSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
