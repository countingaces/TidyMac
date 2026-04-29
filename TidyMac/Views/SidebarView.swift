import SwiftUI

struct SidebarView: View {
    @Binding var selection: NavigationItem

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    SidebarItemRow(
                        item: .smartScan,
                        isSelected: selection == .smartScan,
                        action: { selection = .smartScan }
                    )
                    .padding(.horizontal, 10)

                    ForEach(NavigationSection.allCases) { section in
                        SidebarSection(
                            section: section,
                            selection: $selection
                        )
                    }
                }
                .padding(.vertical, 12)
            }

            Spacer(minLength: 0)
        }
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.accentColor, .accentColor.opacity(0.6)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            Text("TidyMac")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }
}

private struct SidebarSection: View {
    let section: NavigationSection
    @Binding var selection: NavigationItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.bottom, 2)

            VStack(spacing: 2) {
                ForEach(section.items) { item in
                    SidebarItemRow(
                        item: item,
                        isSelected: selection == item,
                        action: { selection = item }
                    )
                }
            }
            .padding(.horizontal, 10)
        }
    }
}

private struct SidebarItemRow: View {
    let item: NavigationItem
    let isSelected: Bool
    let action: () -> Void

    @EnvironmentObject private var appState: AppState
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: item.symbolName)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20, height: 20)
                    .foregroundStyle(iconStyle)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.85))
                        .lineLimit(1)

                    if let badge = appState.sidebarBadges[item] {
                        Text(badge)
                            .font(.caption)
                            .foregroundStyle(item.theme.primary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                // Smart Scan gets a distinct health-score pill (grade
                // color, not the theme color) since the score is the
                // headline metric of the entire app.
                if item == .smartScan, let score = appState.healthScore {
                    HealthScoreBadge(score: score)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var iconStyle: AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(item.theme.gradient)
        } else {
            return AnyShapeStyle(Color.secondary)
        }
    }

    @ViewBuilder
    private var background: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(item.theme.primary.opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(item.theme.primary.opacity(0.25), lineWidth: 0.5)
                )
        } else if isHovered {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        } else {
            Color.clear
        }
    }
}

private struct HealthScoreBadge: View {
    let score: HealthScore
    var body: some View {
        Text("\(score.overall)")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(score.grade.color))
            .help("\(score.grade.label) — \(score.headline)")
    }
}

#Preview {
    SidebarView(selection: .constant(.smartScan))
        .frame(width: 200, height: 650)
        .environmentObject(AppState())
}
