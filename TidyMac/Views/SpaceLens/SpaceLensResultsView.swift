import SwiftUI
import AppKit

struct SpaceLensResultsView: View {
    @ObservedObject var viewModel: SpaceLensViewModel

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbBar(viewModel: viewModel)
            Divider()

            GeometryReader { geo in
                HStack(spacing: 0) {
                    FileListPanel(viewModel: viewModel)
                        .frame(width: max(260, geo.size.width * 0.4))

                    Divider()

                    CirclePackingPanel(viewModel: viewModel)
                        .frame(maxWidth: .infinity)
                }
            }

            Divider()

            BottomBar(viewModel: viewModel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(
            "Remove",
            isPresented: Binding(
                get: { viewModel.removeAlertMessage != nil },
                set: { if !$0 { viewModel.removeAlertMessage = nil } }
            ),
            presenting: viewModel.removeAlertMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }
}

private struct BreadcrumbBar: View {
    @ObservedObject var viewModel: SpaceLensViewModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    BreadcrumbSegment(
                        title: rootLabel,
                        isActive: viewModel.currentPath.isEmpty,
                        action: { viewModel.navigate(toDepth: 0) }
                    )

                    ForEach(Array(viewModel.currentPath.enumerated()), id: \.element.id) { idx, node in
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)

                        BreadcrumbSegment(
                            title: displayName(node),
                            isActive: idx == viewModel.currentPath.count - 1,
                            action: { viewModel.navigate(toDepth: idx + 1) }
                        )
                    }
                }
                .padding(.horizontal, 18)
            }

            Spacer(minLength: 8)

            Button(action: { viewModel.returnToLanding() }) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.uturn.left")
                    Text("New Scan")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
            }
            .buttonStyle(.plain)
            .padding(.trailing, 14)
        }
    }

    private var rootLabel: String {
        guard let root = viewModel.rootNode else {
            return viewModel.diskInfo?.name ?? "Macintosh HD"
        }
        if root.url.path == "/" {
            return viewModel.diskInfo?.name ?? "Macintosh HD"
        }
        return displayName(root)
    }

    private func displayName(_ node: FileNode) -> String {
        if !node.name.isEmpty { return node.name }
        let last = node.url.lastPathComponent
        return last.isEmpty ? "/" : last
    }
}

private struct BreadcrumbSegment: View {
    let title: String
    let isActive: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        ZStack {
            // Bottom layer: nearly-transparent Color that fills the entire frame
            // and is reliably hit-testable. This is what catches taps.
            Color.primary.opacity(0.0001)

            // Top layer: visible pill. Hit testing is disabled at every level —
            // both on the outer view AND on the background shape — because in
            // SwiftUI, .allowsHitTesting(false) on a parent does NOT always
            // propagate into a .background()'s shape, which is why the pill
            // was swallowing taps.
            Text(title)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundStyle(textColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(backgroundFill)
                        .allowsHitTesting(false)
                )
                .allowsHitTesting(false)
        }
        .frame(height: 44)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isActive else { return }
            action()
        }
        .onHover { hovering in
            isHovered = hovering
            guard !isActive else { return }
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private var textColor: Color {
        if isActive { return .primary }
        return isHovered ? .primary : Color.primary.opacity(0.85)
    }

    private var backgroundFill: Color {
        if isActive { return Color.primary.opacity(0.08) }
        if isHovered { return Color.primary.opacity(0.12) }
        return .clear
    }
}

private struct FileListPanel: View {
    @ObservedObject var viewModel: SpaceLensViewModel

    var body: some View {
        let children = viewModel.currentNode?.children ?? []
        let totalSize = max(1, children.reduce(Int64(0)) { $0 + $1.size })

        Group {
            if children.isEmpty {
                EmptyFolderState()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(children) { child in
                            FileRow(
                                node: child,
                                totalSize: totalSize,
                                isSelected: viewModel.selectedItems.contains(child.id),
                                onToggleSelect: { viewModel.selectItem(node: child) },
                                onActivate: {
                                    if child.isDirectory {
                                        viewModel.navigateInto(node: child)
                                    } else {
                                        viewModel.selectItem(node: child)
                                    }
                                }
                            )
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyFolderState: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("This folder is empty")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FileRow: View {
    let node: FileNode
    let totalSize: Int64
    let isSelected: Bool
    let onToggleSelect: () -> Void
    let onActivate: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { isSelected },
                set: { _ in onToggleSelect() }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()

            Image(systemName: node.isDirectory ? "folder.fill" : "doc.fill")
                .font(.system(size: 13))
                .foregroundStyle(node.isDirectory ? AnyShapeStyle(ColorTheme.storage.gradient) : AnyShapeStyle(Color.secondary))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(node.name.isEmpty ? node.url.lastPathComponent : node.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                ProportionBar(fraction: fraction)
            }

            Spacer(minLength: 8)

            Text(node.humanReadableSize)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(rowBackground)
        )
        .onHover { hovering in
            isHovered = hovering
            if hovering && node.isDirectory {
                NSCursor.pointingHand.push()
            } else if !hovering && node.isDirectory {
                NSCursor.pop()
            }
        }
        .onTapGesture { onActivate() }
    }

    private var fraction: CGFloat {
        guard totalSize > 0 else { return 0 }
        return min(1, max(0, CGFloat(node.size) / CGFloat(totalSize)))
    }

    private var rowBackground: Color {
        if isSelected { return ColorTheme.storage.primary.opacity(0.14) }
        if isHovered { return Color.primary.opacity(0.05) }
        return Color.clear
    }
}

private struct ProportionBar: View {
    let fraction: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule()
                    .fill(ColorTheme.storage.gradient)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 3)
    }
}

private struct CirclePackingPanel: View {
    @ObservedObject var viewModel: SpaceLensViewModel

    var body: some View {
        Group {
            if let current = viewModel.currentNode, !current.children.isEmpty {
                CirclePackingView(
                    node: current,
                    selectedItems: viewModel.selectedItems,
                    onNodeTapped: { node in
                        if node.isDirectory {
                            viewModel.navigateInto(node: node)
                        } else {
                            viewModel.selectItem(node: node)
                        }
                    }
                )
                .padding(16)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("Nothing to visualize")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ColorTheme.storage.backgroundGradient)
    }
}

private struct BottomBar: View {
    @ObservedObject var viewModel: SpaceLensViewModel

    var body: some View {
        HStack(spacing: 16) {
            if let info = viewModel.diskInfo {
                HStack(spacing: 10) {
                    Image(systemName: "internaldrive.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(ColorTheme.storage.gradient)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(info.name)
                            .font(.system(size: 12, weight: .semibold))
                        BottomCapacityBar(used: info.usedBytes, total: info.totalBytes)
                            .frame(width: 200)
                        Text("\(humanize(info.usedBytes)) of \(humanize(info.totalBytes)) used")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if !viewModel.selectedItems.isEmpty {
                Text("\(viewModel.selectedItems.count) selected · \(humanize(viewModel.selectedSize))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Button(action: {
                Task { await viewModel.removeSelected() }
            }) {
                HStack(spacing: 6) {
                    if viewModel.isRemoving {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: "trash")
                    }
                    Text(viewModel.isRemoving ? "Removing…" : "Remove")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(removeIsActive ? Color.white : Color.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(removeIsActive
                              ? ColorTheme.storage.primary
                              : Color.primary.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.selectedItems.isEmpty || viewModel.isRemoving)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private func humanize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var removeIsActive: Bool {
        !viewModel.selectedItems.isEmpty && !viewModel.isRemoving
    }
}

private struct BottomCapacityBar: View {
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
