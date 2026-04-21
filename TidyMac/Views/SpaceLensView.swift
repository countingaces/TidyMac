import SwiftUI

struct SpaceLensView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()
                .padding(.horizontal, 32)

            ScrollView {
                VStack(spacing: 20) {
                    Spacer(minLength: 40)

                    ZStack {
                        Circle()
                            .fill(NavigationItem.spaceLens.theme.primary.opacity(0.12))
                            .frame(width: 112, height: 112)

                        Image(systemName: NavigationItem.spaceLens.symbolName)
                            .font(.system(size: 48, weight: .medium))
                            .foregroundStyle(NavigationItem.spaceLens.theme.gradient)
                    }

                    VStack(spacing: 8) {
                        Text("Visualize your storage")
                            .font(.system(size: 22, weight: .semibold, design: .rounded))

                        Text("Choose a folder to analyze and TidyMac will break down how space is being used.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }

                    Spacer(minLength: 20)
                }
                .frame(maxWidth: .infinity)
                .padding(32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(NavigationItem.spaceLens.title)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text(NavigationItem.spaceLens.shortDescription)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 32)
        .padding(.top, 28)
        .padding(.bottom, 20)
    }
}

#Preview {
    SpaceLensView()
        .frame(width: 800, height: 650)
}
