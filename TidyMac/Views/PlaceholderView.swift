import SwiftUI

struct PlaceholderView: View {
    let item: NavigationItem

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(item.theme.primary.opacity(0.12))
                    .frame(width: 104, height: 104)

                Image(systemName: item.symbolName)
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(item.theme.gradient)
            }

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Text(item.title)
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    ComingSoonBadge(theme: item.theme)
                }

                Text(item.shortDescription)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

private struct ComingSoonBadge: View {
    let theme: ColorTheme

    var body: some View {
        Text("Coming Soon")
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(theme.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(theme.primary.opacity(0.14))
            )
            .overlay(
                Capsule()
                    .stroke(theme.primary.opacity(0.25), lineWidth: 0.5)
            )
    }
}

#Preview {
    PlaceholderView(item: .systemJunk)
        .frame(width: 800, height: 650)
}
