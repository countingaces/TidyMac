import SwiftUI

/// Modal sheet shown when the user tries to clean items that need the
/// privileged helper but the helper isn't installed yet. Lists the
/// affected items, explains what the helper does, and offers three
/// paths: Install (primary), Skip (proceed without these items), or
/// Cancel.
///
/// The "Skip These Items" button is the linchpin of the graceful-
/// degradation pattern: TidyMac should never refuse to do anything
/// just because the helper is missing. User-owned cleanup always
/// succeeds; admin items become opt-in.
struct HelperRequiredSheet: View {
    /// Items the caller wanted to clean that the helper would have
    /// handled — surfaced in the sheet so the user sees concretely
    /// what they'd gain from installing.
    struct DeferredItem: Identifiable {
        let id: UUID = UUID()
        let path: URL
        let size: Int64
    }

    let items: [DeferredItem]
    let onInstall: () -> Void
    let onSkip: () -> Void
    let onCancel: () -> Void

    @State private var showWhatItDoes = false
    @StateObject private var manager = PrivilegedHelperManager.shared

    private var totalSize: Int64 {
        items.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            description
            itemList
            disclosure
            Spacer(minLength: 0)
            buttonRow
        }
        .padding(24)
        .frame(width: 540, height: 520)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange.gradient)
            VStack(alignment: .leading, spacing: 2) {
                Text("Administrator Access Required")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text("\(items.count) item\(items.count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var description: some View {
        Text("Some items live in system locations that require administrator privileges to clean. Install TidyMac's Helper Tool to clean them with one password prompt — or skip them and clean only your user-owned files.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var itemList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("REQUIRES HELPER")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(items) { item in
                        HStack(spacing: 8) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                                .frame(width: 14)
                            Text(item.path.path)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                    }
                }
            }
            .frame(maxHeight: 160)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.04))
            )
        }
    }

    private var disclosure: some View {
        DisclosureGroup(isExpanded: $showWhatItDoes) {
            VStack(alignment: .leading, spacing: 4) {
                Text("The helper is a small executable signed by TidyMac's developer ID. macOS validates its signature before installing it. Once running, it accepts only delete operations and only for paths inside this allowlist:")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                ForEach(manager.allowedPrefixes, id: \.self) { prefix in
                    Text(prefix)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.green)
                }
                Text("Anything in /System/, /usr/, /Applications/, /Library/LaunchDaemons/, or /Library/Frameworks/ is permanently denied.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .padding(.top, 4)
        } label: {
            Label("What does the Helper do?", systemImage: "questionmark.circle")
                .font(.system(size: 12))
        }
    }

    private var buttonRow: some View {
        HStack(spacing: 10) {
            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Skip These Items") { onSkip() }
            Button("Install Helper") { onInstall() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
    }
}
