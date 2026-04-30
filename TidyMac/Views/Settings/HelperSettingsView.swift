import SwiftUI

/// Settings panel for managing the privileged helper. Lives in the
/// Settings scene; user reaches it via TidyMac → Settings → Helper Tool.
///
/// Key UX choices:
///   - The "Allowed Locations" disclosure shows the *exact* allowlist
///     the helper enforces (read directly from HelperConstants). Users
///     can verify what the helper can touch without taking our word
///     for it. This is transparency-as-trust — open source enables
///     it, and shipping it in the UI makes it visible.
///   - Uninstall is a first-class button. Most apps make uninstall
///     hard; an open-source tool should leave nothing behind.
struct HelperSettingsView: View {
    @StateObject private var manager = PrivilegedHelperManager.shared
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var showAllowedDisclosure = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    statusDot
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle)
                            .font(.system(size: 13, weight: .semibold))
                        Text(statusDetail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isWorking {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.vertical, 4)

                Text("TidyMac's Helper Tool runs with administrator privileges to clean system files your user account can't access — system caches, logs, developer-tool data. It's code-signed and validated by macOS, and can only delete files in approved system locations.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Status")
            }

            Section {
                HStack(spacing: 10) {
                    Button(installButtonLabel) {
                        Task { await runInstall() }
                    }
                    .disabled(isWorking)

                    if isInstalled {
                        Button("Uninstall Helper") {
                            Task { await runUninstall() }
                        }
                        .disabled(isWorking)
                    }

                    Spacer()
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Installation")
            }

            Section {
                DisclosureGroup(isExpanded: $showAllowedDisclosure) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ALLOWED")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        ForEach(manager.allowedPrefixes, id: \.self) { prefix in
                            Text(prefix)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.green)
                        }
                        Text("DENIED — never deletable, even if also allowed")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                        ForEach(manager.deniedPrefixes, id: \.self) { prefix in
                            Text(prefix)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Label("View Allowed Locations", systemImage: "list.bullet.rectangle")
                        .font(.system(size: 12))
                }
            } header: {
                Text("Transparency")
            } footer: {
                Text("Path validation is two-stage: the denylist runs first (so a denied prefix wins even when also allowed), and every path is resolved through symlinks before checking — that defeats TOCTOU attacks where a symlink under an allowed prefix could redirect into a protected location.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, idealWidth: 540, minHeight: 480)
        .task {
            await manager.refreshStatus()
        }
    }

    // MARK: - Computed display

    private var isInstalled: Bool {
        if case .installed = manager.status { return true }
        if case .needsUpdate = manager.status { return true }
        return false
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 10, height: 10)
    }

    private var statusColor: Color {
        switch manager.status {
        case .installed: return .green
        case .needsUpdate: return .yellow
        case .notInstalled, .unknown: return .gray
        case .error: return .red
        }
    }

    private var statusTitle: String {
        switch manager.status {
        case .installed(let v): return "Helper installed (v\(v))"
        case .needsUpdate(let installed, let required):
            return "Helper update available (v\(installed) → v\(required))"
        case .notInstalled: return "Helper not installed"
        case .unknown: return "Checking helper status…"
        case .error(let msg): return "Helper error: \(msg)"
        }
    }

    private var statusDetail: String {
        switch manager.status {
        case .installed:
            return "Root-owned files are cleanable from the System Junk and Smart Scan tabs."
        case .needsUpdate:
            return "Re-install to register the latest version."
        case .notInstalled:
            return "Some system files (root-owned caches, logs) require admin to delete."
        case .unknown:
            return "Querying SMAppService and the helper's XPC service…"
        case .error:
            return "Try uninstalling and re-installing the helper."
        }
    }

    private var installButtonLabel: String {
        switch manager.status {
        case .installed: return "Reinstall Helper"
        case .needsUpdate: return "Update Helper"
        default: return "Install Helper"
        }
    }

    // MARK: - Actions

    @MainActor
    private func runInstall() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await manager.install()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func runUninstall() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await manager.uninstall()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
