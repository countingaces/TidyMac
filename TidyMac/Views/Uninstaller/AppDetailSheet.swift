import SwiftUI
import AppKit

struct AppDetailSheet: View {
    @ObservedObject var viewModel: UninstallerViewModel
    let app: AppInfo
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            remnantsList
            Divider()
            footer
        }
        .frame(width: 720, height: 600)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(app.name)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    CategoryBadge(category: app.category)
                    Spacer()
                    Button("Done", action: onDismiss)
                        .keyboardShortcut(.cancelAction)
                }
                Text("Version \(app.version) · \(app.id)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 14) {
                    Label(lastUsedText, systemImage: "clock")
                    Label(humanReadableSize(app.bundleSize), systemImage: "internaldrive")
                    if app.isSandboxed {
                        Label("Sandboxed", systemImage: "shield.lefthalf.filled")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var remnantsList: some View {
        if viewModel.scanningAppIds.contains(app.id) {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Looking for associated files…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.remnants(for: app.id).isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(SafetyLevel.safe.color)
                Text("No leftover files found")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(grouped, id: \.category) { group in
                        RemnantGroupView(
                            viewModel: viewModel,
                            appId: app.id,
                            category: group.category,
                            items: group.items
                        )
                    }
                }
                .padding(16)
            }
        }
    }

    private struct CategoryGroup {
        let category: AppRemnant.RemnantCategory
        let items: [AppRemnant]
    }

    private var grouped: [CategoryGroup] {
        let remnants = viewModel.remnants(for: app.id)
        let groupedDict = Dictionary(grouping: remnants, by: { $0.category })
        return AppRemnant.RemnantCategory.allCases.compactMap { category in
            guard let items = groupedDict[category], !items.isEmpty else { return nil }
            return CategoryGroup(
                category: category,
                items: items.sorted { $0.size > $1.size }
            )
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Select All Safe") {
                viewModel.selectAllSafeRemnants(for: app.id)
            }
            .buttonStyle(.link)

            Button("Select All") {
                viewModel.selectAllRemnants(for: app.id)
            }
            .buttonStyle(.link)

            Button("Deselect All") {
                viewModel.deselectAllRemnants(for: app.id)
            }
            .buttonStyle(.link)

            Spacer()

            Text("\(selectedCount) of \(viewModel.remnants(for: app.id).count) selected · \(humanReadableSize(selectedSize))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var selectedCount: Int {
        viewModel.selectedRemnantIds[app.id]?.count ?? 0
    }

    private var selectedSize: Int64 {
        let chosen = viewModel.selectedRemnantIds[app.id] ?? []
        return viewModel.remnants(for: app.id)
            .filter { chosen.contains($0.id) }
            .reduce(Int64(0)) { $0 + $1.size }
    }

    private var lastUsedText: String {
        guard let date = app.lastUsedDate else { return "Never used" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Used " + formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Remnant group

private struct RemnantGroupView: View {
    @ObservedObject var viewModel: UninstallerViewModel
    let appId: String
    let category: AppRemnant.RemnantCategory
    let items: [AppRemnant]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: category.icon)
                    .font(.system(size: 12))
                    .foregroundStyle(viewModel.moduleInfo.colorTheme.primary)
                Text(category.displayName)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(humanReadableSize(totalSize))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 1) {
                ForEach(items) { item in
                    RemnantRow(
                        viewModel: viewModel,
                        appId: appId,
                        item: item
                    )
                }
            }
        }
    }

    private var totalSize: Int64 {
        items.reduce(Int64(0)) { $0 + $1.size }
    }
}

private struct RemnantRow: View {
    @ObservedObject var viewModel: UninstallerViewModel
    let appId: String
    let item: AppRemnant

    @State private var isHovered = false

    var body: some View {
        let isSelected = (viewModel.selectedRemnantIds[appId] ?? []).contains(item.id)

        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { _ in viewModel.toggleRemnant(id: item.id, for: appId) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            Text(displayPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.path.path)

            Spacer(minLength: 8)

            ConfidenceBadge(confidence: item.matchConfidence)

            Text(humanReadableSize(item.size))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 70, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        )
        .contentShape(Rectangle())
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

    private var displayPath: String {
        let homePrefix = NSHomeDirectory() + "/"
        if item.path.path.hasPrefix(homePrefix) {
            return "~/" + String(item.path.path.dropFirst(homePrefix.count))
        }
        return item.path.path
    }
}

private struct ConfidenceBadge: View {
    let confidence: AppRemnant.MatchConfidence

    var body: some View {
        Text(confidence.label)
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(confidence.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(confidence.color.opacity(0.14))
            )
            .help(confidence.label)
    }
}
