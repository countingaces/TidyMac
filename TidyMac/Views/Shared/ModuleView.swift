import SwiftUI
import AppKit

// Generic three-state shell that any ScanModule can render through.
// The detailPane closure is the only module-specific piece — it produces the
// view shown on the right side of the results layout for the focused category.
struct ModuleView<M: ScanModule, DetailContent: View>: View {
    @ObservedObject var module: M
    let onCleanRequest: () -> Void
    @ViewBuilder let detailPane: (ScanCategory<M.ResultType>) -> DetailContent

    var body: some View {
        switch module.scanState {
        case .idle:
            ModuleLandingView(module: module)
        case .scanning(let progress):
            ModuleScanningView(module: module, progress: progress)
        case .complete:
            ModuleResultsView(
                module: module,
                onCleanRequest: onCleanRequest,
                detailPane: detailPane
            )
        case .error(let message):
            ModuleErrorView(module: module, message: message)
        }
    }
}

// MARK: - Landing

struct ModuleLandingView<M: ScanModule>: View {
    @ObservedObject var module: M

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 10) {
                Text(module.moduleInfo.title)
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                Text(module.moduleInfo.description)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 34)

            VStack(spacing: 18) {
                ForEach(module.moduleInfo.features) { feature in
                    ModuleFeatureBullet(feature: feature, theme: module.moduleInfo.colorTheme)
                }
            }
            .frame(maxWidth: 460, alignment: .leading)
            .padding(.bottom, 36)

            ModuleScanButton(theme: module.moduleInfo.colorTheme) {
                module.beginScan()
            }

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

struct ModuleFeatureBullet: View {
    let feature: ModuleInfo.Feature
    let theme: ColorTheme

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(theme.primary.opacity(0.14))
                Image(systemName: feature.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.gradient)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title)
                    .font(.system(size: 14, weight: .semibold))
                Text(feature.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ModuleScanButton: View {
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

struct ModuleScanningView<M: ScanModule>: View {
    @ObservedObject var module: M
    let progress: ScanProgress
    @State private var rotation: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            spinner.padding(.bottom, 24)

            VStack(spacing: 8) {
                Text(progress.currentActivity.isEmpty ? "Scanning…" : progress.currentActivity)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))

                Text("\(progress.itemsFound.formatted()) item\(progress.itemsFound == 1 ? "" : "s") · \(humanReadableSize(progress.sizeFound))")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(module.moduleInfo.colorTheme.primary)
                    .monospacedDigit()
                    .padding(.top, 6)
            }

            Spacer()

            Button(action: { module.cancelScan() }) {
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
                    module.moduleInfo.colorTheme.gradient,
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .frame(width: 96, height: 96)
                .rotationEffect(.degrees(rotation))
                .onAppear {
                    withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                        rotation = 360
                    }
                }

            Image(systemName: module.moduleInfo.icon)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(module.moduleInfo.colorTheme.gradient)
        }
    }
}

// MARK: - Results

struct ModuleResultsView<M: ScanModule, DetailContent: View>: View {
    @ObservedObject var module: M
    let onCleanRequest: () -> Void
    @ViewBuilder let detailPane: (ScanCategory<M.ResultType>) -> DetailContent

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ModuleCategoryListPanel(module: module)
                        .frame(width: max(280, geo.size.width * 0.36))

                    Divider()

                    Group {
                        if let category = module.selectedCategory {
                            detailPane(category)
                        } else {
                            EmptyDetailPlaceholder()
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            Divider()

            ModuleBottomActionBar(module: module, onCleanRequest: onCleanRequest)
        }
    }
}

private struct EmptyDetailPlaceholder: View {
    var body: some View {
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

// MARK: - Category list (left panel)

struct ModuleCategoryListPanel<M: ScanModule>: View {
    @ObservedObject var module: M

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    module.deselectAll()
                } label: {
                    Text("Deselect All")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.link)
                .disabled(module.selectedItemIds.isEmpty)

                Spacer()

                Picker("", selection: Binding(
                    get: { module.sortMode },
                    set: { module.sortMode = $0 }
                )) {
                    Text("Size").tag(SortMode.size)
                    Text("Name").tag(SortMode.name)
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
                    ForEach(module.sortedCategories) { category in
                        ModuleCategoryRow(module: module, category: category)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            }
        }
    }
}

struct ModuleCategoryRow<M: ScanModule>: View {
    @ObservedObject var module: M
    let category: ScanCategory<M.ResultType>
    @State private var isHovered = false

    var body: some View {
        let theme = module.moduleInfo.colorTheme
        let isFocused = module.selectedCategoryId == category.id
        let selectionState = module.selectionState(for: category)
        let safety = module.safetyLevel(for: category)

        HStack(spacing: 10) {
            CategoryCheckbox(state: selectionState, theme: theme) {
                module.toggleCategory(id: category.id)
            }

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
                    if safety != .safe {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(safety.color)
                            .help(safety.description)
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
                .fill(rowBackground(focused: isFocused, theme: theme))
        )
        .opacity(category.itemCount == 0 ? 0.55 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture { module.selectedCategoryId = category.id }
        .onHover { isHovered = $0 }
    }

    private func rowBackground(focused: Bool, theme: ColorTheme) -> Color {
        if focused { return theme.primary.opacity(0.14) }
        if isHovered { return Color.primary.opacity(0.05) }
        return .clear
    }
}

struct CategoryCheckbox: View {
    let state: SelectionState
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

// MARK: - Bottom action bar

struct ModuleBottomActionBar<M: ScanModule>: View {
    @ObservedObject var module: M
    let onCleanRequest: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button {
                module.returnToIdle()
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
                if module.selectedItems.isEmpty {
                    Text("Nothing selected")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(module.selectedItems.count) item\(module.selectedItems.count == 1 ? "" : "s") selected")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(humanReadableSize(module.selectedSize))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(module.moduleInfo.colorTheme.primary)
                        .monospacedDigit()
                }
            }

            Button(action: onCleanRequest) {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                    Text("Clean")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(canClean ? Color.white : Color.secondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(canClean ? module.moduleInfo.colorTheme.primary : Color.primary.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .disabled(!canClean)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var canClean: Bool {
        !module.selectedItems.isEmpty
    }
}

// MARK: - Error

struct ModuleErrorView<M: ScanModule>: View {
    @ObservedObject var module: M
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
            Button("Try again") { module.beginScan() }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

// MARK: - Safety badge (used in detail panes)

struct SafetyBadge: View {
    let level: SafetyLevel

    var body: some View {
        Text(level.shortLabel)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(level.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(level.color.opacity(0.14)))
            .overlay(Capsule().stroke(level.color.opacity(0.3), lineWidth: 0.5))
    }
}

// MARK: - File-private utility

func humanReadableSize(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
