import Foundation
import SwiftUI

@MainActor
final class MaintenanceViewModel: ObservableObject {
    enum RunState {
        case idle
        case previewing
        case running(currentTaskId: String, completed: Int, total: Int)
        case finished([RunOutcome])
    }

    struct RunOutcome: Identifiable {
        let id: String
        let taskName: String
        let result: MaintenanceTaskResult?
        let error: String?
    }

    @Published var tasks: [any MaintenanceTask] = []
    @Published var selectedIds: Set<String> = []
    @Published var focusedTaskId: String?
    @Published var previews: [String: MaintenanceTaskPreview] = [:]
    @Published var lastRunDates: [String: Date] = [:]
    @Published var runState: RunState = .idle

    let theme: ColorTheme = .speed

    private let lastRunDefaultsKey = "TidyMac.MaintenanceLastRun"

    init() {
        loadLastRunDates()
    }

    func load() async {
        tasks = MaintenanceCatalog.availableTasks()
        if focusedTaskId == nil {
            focusedTaskId = tasks.first?.id
        }
        // Compute previews for all tasks lazily so the right pane has
        // something to show without the user clicking "Preview" first.
        await refreshAllPreviews()
    }

    func task(id: String) -> (any MaintenanceTask)? {
        tasks.first { $0.id == id }
    }

    var focusedTask: (any MaintenanceTask)? {
        guard let id = focusedTaskId else { return nil }
        return task(id: id)
    }

    var selectedTasks: [any MaintenanceTask] {
        tasks.filter { selectedIds.contains($0.id) }
    }

    var hasSelection: Bool { !selectedIds.isEmpty }

    var mostRecentRunDate: Date? {
        lastRunDates.values.max()
    }

    // MARK: - Selection

    func toggle(id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    func focus(id: String) {
        focusedTaskId = id
    }

    func selectAll() {
        selectedIds = Set(tasks.map { $0.id })
    }

    func deselectAll() {
        selectedIds.removeAll()
    }

    // MARK: - Previews

    func refreshAllPreviews() async {
        var fresh: [String: MaintenanceTaskPreview] = [:]
        for task in tasks {
            fresh[task.id] = await task.dryRun()
        }
        previews = fresh
    }

    func refreshPreview(id: String) async {
        guard let task = task(id: id) else { return }
        previews[id] = await task.dryRun()
    }

    // MARK: - Execution

    /// Runs the selected tasks one at a time. Sequential (not parallel)
    /// because several of them prompt for the admin password — running
    /// them in parallel would stack auth dialogs on top of each other and
    /// the user couldn't tell which prompt belongs to which task.
    func runSelected() async {
        let toRun = selectedTasks
        guard !toRun.isEmpty else { return }

        var outcomes: [RunOutcome] = []
        for (idx, task) in toRun.enumerated() {
            runState = .running(
                currentTaskId: task.id,
                completed: idx,
                total: toRun.count
            )
            do {
                let result = try await task.execute()
                outcomes.append(RunOutcome(
                    id: task.id,
                    taskName: task.name,
                    result: result,
                    error: nil
                ))
                lastRunDates[task.id] = Date()
                saveLastRunDates()
            } catch {
                outcomes.append(RunOutcome(
                    id: task.id,
                    taskName: task.name,
                    result: nil,
                    error: error.localizedDescription
                ))
            }
        }
        runState = .finished(outcomes)
    }

    /// "Run all non-admin tasks" entry point used by the menu bar item.
    func runAllNonAdmin() async {
        selectedIds = Set(tasks.filter { !$0.requiresAdmin }.map { $0.id })
        await runSelected()
    }

    func dismissResults() {
        runState = .idle
    }

    // MARK: - Persistence

    private func loadLastRunDates() {
        guard let raw = UserDefaults.standard.dictionary(forKey: lastRunDefaultsKey) else { return }
        var parsed: [String: Date] = [:]
        for (key, value) in raw {
            if let interval = value as? TimeInterval {
                parsed[key] = Date(timeIntervalSince1970: interval)
            }
        }
        lastRunDates = parsed
    }

    private func saveLastRunDates() {
        let serialized = lastRunDates.mapValues { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(serialized, forKey: lastRunDefaultsKey)
    }
}
