import SwiftUI

/// The three pages of the video at the top of the window: icon and name, the current one in
/// the accent color with a sliding underline.
struct ScreenTabs: View {
    let selected: EpisodeScreen
    let isEnabled: Bool
    let select: (EpisodeScreen) -> Void
    @Namespace private var underline
    @State private var hovered: EpisodeScreen?

    var body: some View {
        HStack(spacing: Theme.Spacing.xl) {
            ForEach(EpisodeScreen.allCases) { screen in tab(screen) }
        }
        .padding(.horizontal, Theme.Spacing.m)
        .animation(.snappy(duration: 0.25), value: selected)
        .opacity(isEnabled ? 1 : 0.5)
        .allowsHitTesting(isEnabled)
    }

    private func tab(_ screen: EpisodeScreen) -> some View {
        let isSelected = screen == selected
        return Button { select(screen) } label: {
            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: screen.systemImage)
                    Text(screen.label)
                }
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : hovered == screen ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                ZStack {
                    Color.clear.frame(height: 2.5)
                    if isSelected {
                        Capsule().fill(.tint).frame(height: 2.5).matchedGeometryEffect(id: "underline", in: underline)
                    }
                }
            }
            .fixedSize()
            .padding(.top, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? screen : (hovered == screen ? nil : hovered) }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .hintVerbatim(screen.label, screen.hint)
    }
}
