import SwiftUI

/// One option of a short list of choices in a sheet (a radio button with a title and a line
/// of explanation); disabled options say why below the title.
struct ChoiceRow<Detail: View>: View {
    let title: String
    let selected: Bool
    var disabledReason: String?
    let action: () -> Void
    @ViewBuilder var detail: Detail

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Button(action: action) {
                HStack(spacing: Theme.Spacing.s) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    Text(title).font(.callout.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(disabledReason != nil)
            .hintVerbatim(title, disabledReason ?? "Escolhe esta opção.")
            if let disabledReason {
                Text(disabledReason).font(.caption).foregroundStyle(.secondary).padding(.leading, 24)
            } else if selected {
                detail.padding(.leading, 24)
            }
        }
        .opacity(disabledReason == nil ? 1 : 0.55)
    }
}
