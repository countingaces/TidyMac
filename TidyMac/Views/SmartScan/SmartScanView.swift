import SwiftUI

struct SmartScanView: View {
    @StateObject private var viewModel = SmartScanViewModel()
    @EnvironmentObject private var appState: AppState
    @StateObject private var maintenanceVM = MaintenanceViewModel()

    var body: some View {
        Group {
            switch viewModel.cleanState {
            case .cleaning(let progress):
                CleaningProgressView(
                    progress: progress,
                    theme: NavigationItem.smartScan.theme,
                    onStop: { viewModel.cancelCleaning() }
                )
            case .finished(let result):
                CleaningCompleteView(
                    result: result,
                    theme: NavigationItem.smartScan.theme,
                    onStartOver: { viewModel.dismissCleaningResult() }
                )
            case .idle:
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: viewModel.results) { _, _ in
            publishToAppState()
        }
        .onChange(of: appState.pendingAction) { _, _ in
            handlePendingActionIfReady()
        }
        .onAppear {
            publishToAppState()
            handlePendingActionIfReady()
        }
    }

    private func handlePendingActionIfReady() {
        guard appState.pendingAction == .runSmartScan else { return }
        appState.pendingAction = nil
        Task {
            if maintenanceVM.tasks.isEmpty { await maintenanceVM.load() }
            viewModel.startScan(maintenanceLastRunDates: maintenanceVM.lastRunDates)
        }
    }

    private func publishToAppState() {
        appState.healthScore = viewModel.results?.healthScore
        appState.smartScanResults = viewModel.results
        appState.lastSmartScanDate = viewModel.results?.timestamp
        // Hand off the actual scanned items so SystemJunk and Uninstaller
        // can show pre-populated results when the user clicks Review
        // Details, instead of running their own scans from scratch.
        appState.smartScanJunkCategories = viewModel.orchestrator.lastJunkCategories
        appState.smartScanOrphans = viewModel.orchestrator.lastOrphans
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.orchestrator.overallState {
        case .scanning, .completing:
            ScanningView(viewModel: viewModel)
        case .complete:
            ResultsView(viewModel: viewModel, maintenanceVM: maintenanceVM)
        case .error(let message):
            ErrorView(message: message, viewModel: viewModel, maintenanceVM: maintenanceVM)
        case .idle:
            if viewModel.hasResults {
                ResultsView(viewModel: viewModel, maintenanceVM: maintenanceVM)
            } else {
                LandingView(viewModel: viewModel, maintenanceVM: maintenanceVM)
            }
        }
    }
}

// MARK: - Landing (no previous scan)

private struct LandingView: View {
    @ObservedObject var viewModel: SmartScanViewModel
    @ObservedObject var maintenanceVM: MaintenanceViewModel

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            ZStack {
                Circle()
                    .fill(NavigationItem.smartScan.theme.primary.opacity(0.12))
                    .frame(width: 132, height: 132)
                Image(systemName: NavigationItem.smartScan.symbolName)
                    .font(.system(size: 56, weight: .medium))
                    .foregroundStyle(NavigationItem.smartScan.theme.gradient)
            }

            VStack(spacing: 8) {
                Text("Welcome to TidyMac")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("Start with a scan of your Mac to find what's worth cleaning, fixing, or freeing up.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            Spacer()

            ScanButton(viewModel: viewModel, maintenanceVM: maintenanceVM, label: "Scan")
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Scanning

private struct ScanningView: View {
    @ObservedObject var viewModel: SmartScanViewModel
    @State private var rotation: Double = 0

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 6) {
                Text("Looking at it…")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                Text(currentDetail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 32) {
                ForEach(orderedModules, id: \.0) { (id, label, icon) in
                    ModuleStatusTile(
                        label: label,
                        icon: icon,
                        progress: viewModel.orchestrator.moduleStates[id]
                    )
                }
            }
            .padding(.horizontal, 24)

            Spacer()

            // Stop button + ring around the running progress.
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 6)
                    .frame(width: 120, height: 120)
                Circle()
                    .trim(from: 0, to: max(0.04, overallProgress))
                    .stroke(NavigationItem.smartScan.theme.gradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 120, height: 120)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.3), value: overallProgress)

                Button(action: { viewModel.stopScan() }) {
                    Text("Stop")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(
                            Capsule().fill(Color.red.opacity(0.85))
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var orderedModules: [(String, String, String)] {
        [
            ("systemJunk",   "Cleanup",         "trash.circle.fill"),
            ("optimization", "Startup Health",  "gauge.with.dots.needle.67percent"),
            ("maintenance",  "Maintenance",     "wrench.and.screwdriver.fill"),
            ("orphans",      "Orphaned Files",  "questionmark.folder.fill")
        ]
    }

    private var overallProgress: Double {
        if case .scanning(_, let p) = viewModel.orchestrator.overallState { return p }
        if case .completing = viewModel.orchestrator.overallState { return 0.95 }
        return 0
    }

    private var currentDetail: String {
        for module in orderedModules {
            if let progress = viewModel.orchestrator.moduleStates[module.0],
               case .running(let detail) = progress.state {
                return detail
            }
        }
        if case .completing = viewModel.orchestrator.overallState {
            return "Computing health score…"
        }
        return "Starting scan…"
    }
}

private struct ModuleStatusTile: View {
    let label: String
    let icon: String
    let progress: SmartScanOrchestrator.ModuleProgress?

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(circleFill)
                    .frame(width: 56, height: 56)
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(iconColor)
                if isRunning {
                    Circle()
                        .stroke(Color.primary.opacity(0.10), lineWidth: 2)
                        .frame(width: 56, height: 56)
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(NavigationItem.smartScan.theme.gradient, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 56, height: 56)
                        .rotationEffect(.degrees(rotation))
                        .onAppear {
                            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                                rotation = 360
                            }
                        }
                }
            }

            Text(label)
                .font(.system(size: 12, weight: .semibold))
            Text(stateLabel)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    @State private var rotation: Double = 0

    private var isRunning: Bool {
        guard let progress else { return false }
        if case .running = progress.state { return true }
        return false
    }

    private var isComplete: Bool {
        guard let progress else { return false }
        if case .complete = progress.state { return true }
        return false
    }

    private var isFailed: Bool {
        guard let progress else { return false }
        if case .failed = progress.state { return true }
        return false
    }

    private var circleFill: Color {
        if isComplete { return NavigationItem.smartScan.theme.primary.opacity(0.12) }
        if isFailed { return Color.red.opacity(0.12) }
        if isRunning { return NavigationItem.smartScan.theme.primary.opacity(0.18) }
        return Color.primary.opacity(0.06)
    }

    private var iconColor: AnyShapeStyle {
        if isFailed { return AnyShapeStyle(Color.red) }
        if isRunning || isComplete {
            return AnyShapeStyle(NavigationItem.smartScan.theme.gradient)
        }
        return AnyShapeStyle(Color.secondary)
    }

    private var stateLabel: String {
        guard let progress else { return "Pending" }
        switch progress.state {
        case .pending: return "Pending"
        case .running: return "Running…"
        case .complete(let summary): return summary
        case .failed(let err): return "Failed: \(err)"
        case .skipped(let reason): return reason
        }
    }
}

// MARK: - Results

private struct ResultsView: View {
    @ObservedObject var viewModel: SmartScanViewModel
    @ObservedObject var maintenanceVM: MaintenanceViewModel
    @EnvironmentObject private var appState: AppState
    @State private var showCleanConfirm = false

    var body: some View {
        guard let results = viewModel.results else {
            return AnyView(EmptyView())
        }

        return AnyView(
            ScrollView {
                VStack(spacing: 24) {
                    HealthHeader(score: results.healthScore, lastScan: results.timestamp)
                        .padding(.top, 24)

                    VStack(spacing: 12) {
                        if let junk = results.systemJunk {
                            ResultCard(
                                title: "Cleanup",
                                icon: "trash.circle.fill",
                                primary: ByteCountFormatter.string(fromByteCount: junk.totalSize, countStyle: .file),
                                detail: junk.totalSize == 0 ? "Nothing to clean" : "of cleanable junk found",
                                navigateTo: .systemJunk
                            )
                        }
                        if let opt = results.optimization {
                            ResultCard(
                                title: "Startup Health",
                                icon: "gauge.with.dots.needle.67percent",
                                primary: opt.issueCount == 0 ? "No issues" : "\(opt.issueCount) issue\(opt.issueCount == 1 ? "" : "s")",
                                detail: opt.headline,
                                navigateTo: .optimization
                            )
                        }
                        if let maint = results.maintenance {
                            ResultCard(
                                title: "Maintenance",
                                icon: "wrench.and.screwdriver.fill",
                                primary: maint.overdueCount == 0 ? "Up to date" : "\(maint.overdueCount) task\(maint.overdueCount == 1 ? "" : "s")",
                                detail: maint.overdueCount == 0 ? "Recent maintenance has been run" : "recommended",
                                navigateTo: .maintenance
                            )
                        }
                        if let orphans = results.orphanedFiles, orphans.count > 0 {
                            ResultCard(
                                title: "Orphaned App Data",
                                icon: "questionmark.folder.fill",
                                primary: ByteCountFormatter.string(fromByteCount: orphans.totalSize, countStyle: .file),
                                detail: orphans.headline,
                                navigateTo: .uninstaller
                            )
                        }
                    }
                    .padding(.horizontal, 24)

                    if let recommendation = results.healthScore.recommendation {
                        RecommendationBanner(text: recommendation)
                            .padding(.horizontal, 24)
                    }

                    HStack(spacing: 12) {
                        ScanButton(viewModel: viewModel, maintenanceVM: maintenanceVM, label: "Scan Again", style: .secondary)
                        if viewModel.safeCleanableSize > 0 {
                            Button {
                                showCleanConfirm = true
                            } label: {
                                Text("Clean \(ByteCountFormatter.string(fromByteCount: viewModel.safeCleanableSize, countStyle: .file))")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 22)
                                    .padding(.vertical, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(NavigationItem.smartScan.theme.gradient)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
            .confirmationDialog(
                "Clean \(ByteCountFormatter.string(fromByteCount: viewModel.safeCleanableSize, countStyle: .file)) of system junk?",
                isPresented: $showCleanConfirm,
                titleVisibility: .visible
            ) {
                Button("Clean", role: .destructive) {
                    viewModel.cleanSafeJunk(maintenanceLastRunDates: maintenanceVM.lastRunDates)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes \(viewModel.safeCleanableCount) safe-rated items from the System Junk scan. Items go to the Trash so you can recover them.")
            }
        )
    }
}

// MARK: - Result subviews

private struct HealthHeader: View {
    let score: HealthScore
    let lastScan: Date

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 8)
                    .frame(width: 156, height: 156)
                Circle()
                    .trim(from: 0, to: CGFloat(score.overall) / 100)
                    .stroke(score.grade.color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 156, height: 156)
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text("\(score.overall)")
                        .font(.system(size: 56, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(score.grade.label.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.0)
                        .foregroundStyle(score.grade.color)
                }
            }

            Text(score.headline)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            Text("Last scanned \(relativeDateString(lastScan))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

private struct ResultCard: View {
    let title: String
    let icon: String
    let primary: String
    let detail: String
    let navigateTo: NavigationItem
    @EnvironmentObject private var appState: AppState
    @State private var isHovered = false

    var body: some View {
        Button {
            appState.selection = navigateTo
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(navigateTo.theme.primary.opacity(0.14))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.system(size: 20))
                        .foregroundStyle(navigateTo.theme.gradient)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(primary)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: 4) {
                    Text("Review Details")
                    Image(systemName: "chevron.right")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(navigateTo.theme.primary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovered ? Color.primary.opacity(0.04) : Color.primary.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private struct RecommendationBanner: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 14))
                .foregroundStyle(.yellow)
            Text(text)
                .font(.system(size: 12))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.yellow.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.yellow.opacity(0.25), lineWidth: 0.5)
        )
    }
}

// MARK: - Scan button

private struct ScanButton: View {
    @ObservedObject var viewModel: SmartScanViewModel
    @ObservedObject var maintenanceVM: MaintenanceViewModel
    let label: String
    var style: Style = .primary
    @State private var isHovered = false

    enum Style { case primary, secondary }

    var body: some View {
        Button {
            viewModel.startScan(maintenanceLastRunDates: maintenanceVM.lastRunDates)
        } label: {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(style == .primary ? .white : NavigationItem.smartScan.theme.primary)
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .background(background)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .task {
            // Lazy-load maintenance tasks so lastRunDates is populated
            // before the user clicks Scan.
            if maintenanceVM.tasks.isEmpty { await maintenanceVM.load() }
        }
    }

    @ViewBuilder
    private var background: some View {
        if style == .primary {
            RoundedRectangle(cornerRadius: 10)
                .fill(NavigationItem.smartScan.theme.gradient)
                .opacity(isHovered ? 0.9 : 1.0)
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(NavigationItem.smartScan.theme.primary.opacity(isHovered ? 0.14 : 0.10))
        }
    }
}

// MARK: - Error

private struct ErrorView: View {
    let message: String
    @ObservedObject var viewModel: SmartScanViewModel
    @ObservedObject var maintenanceVM: MaintenanceViewModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text("Smart Scan failed")
                .font(.system(size: 16, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            ScanButton(viewModel: viewModel, maintenanceVM: maintenanceVM, label: "Try Again", style: .primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
