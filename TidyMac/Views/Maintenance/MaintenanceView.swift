import SwiftUI

struct MaintenanceView: View {
    @StateObject private var viewModel = MaintenanceViewModel()
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            switch viewModel.runState {
            case .running(let currentId, let completed, let total):
                RunningView(
                    currentTask: viewModel.task(id: currentId),
                    completed: completed,
                    total: total,
                    theme: viewModel.theme
                )
            case .finished(let outcomes):
                ResultsView(
                    outcomes: outcomes,
                    theme: viewModel.theme,
                    onDismiss: { viewModel.dismissResults() }
                )
            case .idle, .previewing:
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if viewModel.tasks.isEmpty {
                await viewModel.load()
            }
            handlePendingActionIfReady()
        }
        .onChange(of: viewModel.lastRunDates) { _, _ in
            updateBadge()
        }
        .onChange(of: appState.pendingAction) { _, _ in
            handlePendingActionIfReady()
        }
        .onAppear { updateBadge() }
    }

    private func handlePendingActionIfReady() {
        guard appState.pendingAction == .runMaintenanceTasks,
              !viewModel.tasks.isEmpty else { return }
        appState.pendingAction = nil
        Task { await viewModel.runAllNonAdmin() }
    }

    private func updateBadge() {
        if let date = viewModel.mostRecentRunDate {
            appState.sidebarBadges[.maintenance] = "Last: \(relativeDateString(date))"
            appState.lastScanDates[.maintenance] = date
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                TaskList(viewModel: viewModel)
                    .frame(width: 320)
                Divider()
                DetailPane(viewModel: viewModel)
                    .frame(maxWidth: .infinity)
            }
            Divider()
            BottomBar(viewModel: viewModel)
        }
    }
}

// MARK: - Task list

private struct TaskList: View {
    @ObservedObject var viewModel: MaintenanceViewModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(viewModel.tasks, id: \.id) { task in
                    TaskRow(task: task, viewModel: viewModel)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
        }
        .background(Color.primary.opacity(0.02))
    }
}

private struct TaskRow: View {
    let task: any MaintenanceTask
    @ObservedObject var viewModel: MaintenanceViewModel
    @State private var isHovered = false

    var body: some View {
        let isFocused = viewModel.focusedTaskId == task.id
        let isSelected = viewModel.selectedIds.contains(task.id)
        let theme = viewModel.theme

        Button {
            viewModel.focus(id: task.id)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { isSelected },
                    set: { _ in viewModel.toggle(id: task.id) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()

                Image(systemName: task.icon)
                    .font(.system(size: 16))
                    .foregroundStyle(isFocused ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(Color.secondary))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(task.name)
                            .font(.system(size: 13, weight: isFocused ? .semibold : .medium))
                        if task.requiresAdmin {
                            Text("ADMIN")
                                .font(.system(size: 8, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.orange.opacity(0.14)))
                        }
                    }
                    Text(task.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(lastRunText)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(background(focused: isFocused, theme: theme))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder
    private func background(focused: Bool, theme: ColorTheme) -> some View {
        if focused {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.primary.opacity(0.12))
        } else if isHovered {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        } else {
            Color.clear
        }
    }

    private var lastRunText: String {
        guard let date = viewModel.lastRunDates[task.id] else { return "Never run" }
        return "Last run: \(relativeDateString(date))"
    }
}

// MARK: - Detail pane

private struct DetailPane: View {
    @ObservedObject var viewModel: MaintenanceViewModel

    var body: some View {
        if let task = viewModel.focusedTask {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Header(task: task, theme: viewModel.theme)

                    Section(title: "What this does") {
                        Text(task.description)
                            .font(.system(size: 13))
                    }

                    Section(title: "Estimated duration") {
                        Label(task.estimatedDuration, systemImage: "clock")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }

                    if let preview = viewModel.previews[task.id] {
                        Section(title: "Preview") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(preview.description)
                                    .font(.system(size: 13))
                                ImpactBadge(impact: preview.estimatedImpact, theme: viewModel.theme)
                            }
                        }

                        if !preview.warnings.isEmpty {
                            Section(title: "Warnings") {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(preview.warnings, id: \.self) { warning in
                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: "exclamationmark.triangle.fill")
                                                .foregroundStyle(.orange)
                                            Text(warning)
                                                .font(.system(size: 12))
                                        }
                                    }
                                }
                            }
                        }
                    }

                    if let warning = task.warning {
                        Section(title: "Note") {
                            Text(warning)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(20)
            }
        } else {
            VStack {
                Spacer()
                Text("Select a task to see details")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct Header: View {
    let task: any MaintenanceTask
    let theme: ColorTheme

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.primary.opacity(0.15))
                    .frame(width: 48, height: 48)
                Image(systemName: task.icon)
                    .font(.system(size: 22))
                    .foregroundStyle(theme.gradient)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(task.name)
                    .font(.system(size: 18, weight: .semibold))
                if task.requiresAdmin {
                    Text("Requires administrator password")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
        }
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

private struct ImpactBadge: View {
    let impact: MaintenanceTaskPreview.Impact
    let theme: ColorTheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(impact.rawValue)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
    }

    private var icon: String {
        switch impact {
        case .minimal: return "circle"
        case .moderate: return "circle.lefthalf.filled"
        case .significant: return "circle.fill"
        }
    }

    private var color: Color {
        switch impact {
        case .minimal: return .secondary
        case .moderate: return theme.primary
        case .significant: return .orange
        }
    }
}

// MARK: - Bottom bar

private struct BottomBar: View {
    @ObservedObject var viewModel: MaintenanceViewModel

    var body: some View {
        HStack(spacing: 12) {
            if viewModel.hasSelection {
                Button("Deselect All") {
                    viewModel.deselectAll()
                }
                .buttonStyle(.link)
            } else {
                Button("Select All") {
                    viewModel.selectAll()
                }
                .buttonStyle(.link)
            }

            Spacer()

            Text("\(viewModel.selectedIds.count) task\(viewModel.selectedIds.count == 1 ? "" : "s") selected")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Button {
                Task { await viewModel.runSelected() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                    Text("Run")
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(viewModel.hasSelection ? Color.white : Color.secondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(viewModel.hasSelection ? viewModel.theme.primary : Color.primary.opacity(0.08))
                )
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.hasSelection)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Running

private struct RunningView: View {
    let currentTask: (any MaintenanceTask)?
    let completed: Int
    let total: Int
    let theme: ColorTheme

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView(value: Double(completed), total: Double(total))
                .progressViewStyle(.linear)
                .frame(maxWidth: 320)
                .tint(theme.primary)

            VStack(spacing: 4) {
                if let task = currentTask {
                    Text("Running \(task.name)…")
                        .font(.system(size: 16, weight: .semibold))
                }
                Text("\(completed) of \(total) complete")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Results

private struct ResultsView: View {
    let outcomes: [MaintenanceViewModel.RunOutcome]
    let theme: ColorTheme
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Image(systemName: outcomes.contains(where: { $0.error != nil }) ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(theme.gradient)
                Text("Maintenance complete")
                    .font(.system(size: 18, weight: .semibold))
                Text("\(outcomes.filter { $0.error == nil }.count) of \(outcomes.count) succeeded")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 36)
            .padding(.bottom, 18)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(outcomes) { outcome in
                        OutcomeRow(outcome: outcome, theme: theme)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
    }
}

private struct OutcomeRow: View {
    let outcome: MaintenanceViewModel.RunOutcome
    let theme: ColorTheme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: outcome.error == nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(outcome.error == nil ? Color.green : Color.red)
                .font(.system(size: 16))

            VStack(alignment: .leading, spacing: 3) {
                Text(outcome.taskName)
                    .font(.system(size: 13, weight: .semibold))
                if let error = outcome.error {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                } else if let result = outcome.result {
                    Text(result.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

// MARK: - Helpers

func relativeDateString(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
}
