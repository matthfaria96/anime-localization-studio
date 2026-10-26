import SwiftUI

/// Visual language of the app: one accent (sakura), quiet neutrals from the system, generous
/// spacing on an 4-pt grid, and depth from materials rather than borders or heavy shadows.
enum Theme {
    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 10
        static let large: CGFloat = 14
    }

    /// The brand accent comes from the asset catalog (`AccentColor`), so system controls,
    /// selection and focus rings all share it.
    static let accent = Color.accentColor
    static let translated = Color(red: 0.20, green: 0.70, blue: 0.48)
    static let warning = Color.orange
    static let failure = Color.red

    static let monoDigits = Font.system(.body, design: .monospaced).monospacedDigit()
    static let caption = Font.system(.caption).weight(.medium)
}

// MARK: Building blocks

/// Small uppercase label above a group of controls, like the inspectors of Apple's pro apps.
struct SectionLabel: View {
    let title: LocalizedStringKey
    var systemImage: String?

    init(_ title: LocalizedStringKey, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(title)
        }
        .font(.caption.weight(.semibold))
        .textCase(.uppercase)
        .tracking(0.4)
        .foregroundStyle(.secondary)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A quiet grouped surface for inspector panels.
struct Panel<Content: View>: View {
    var padding: CGFloat = Theme.Spacing.l
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: .rect(cornerRadius: Theme.Radius.large))
    }
}

/// Compact capsule for languages, codecs and flags.
struct Tag: View {
    let text: String
    var tint: Color = .secondary
    var filled = false

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(filled ? Color.white : tint)
            .background(filled ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.14)), in: .capsule)
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
    }
}

/// Centered placeholder for empty states, with one clear next action.
struct EmptyStateView<Actions: View>: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let systemImage: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
                .symbolRenderingMode(.hierarchical)
            VStack(spacing: Theme.Spacing.xs) {
                Text(title).font(.title2.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            HStack(spacing: Theme.Spacing.s) { actions }
                .padding(.top, Theme.Spacing.xs)
        }
        .padding(Theme.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Progress line used by long operations: label, determinate bar and a cancel button.
struct OperationProgress: View {
    let message: String
    let fraction: Double?
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text(message).font(.callout).lineLimit(1)
                Spacer()
                if let fraction { Text(fraction, format: .percent.precision(.fractionLength(0))).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                if let onCancel {
                    Button("Cancelar", systemImage: "xmark.circle.fill", action: onCancel)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Cancelar")
                }
            }
            if let fraction { ProgressView(value: fraction).progressViewStyle(.linear) } else { ProgressView().progressViewStyle(.linear) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Inline message for errors, warnings and successes, with an icon that carries the meaning
/// besides the color (for color-blind users and VoiceOver).
struct InlineMessage: View {
    enum Kind { case info, success, warning, error }
    let kind: Kind
    let text: String

    var body: some View {
        Label {
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        } icon: {
            Image(systemName: icon).foregroundStyle(color)
        }
        .padding(Theme.Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.10), in: .rect(cornerRadius: Theme.Radius.medium))
    }

    private var icon: String {
        switch kind {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch kind {
        case .info: .accentColor
        case .success: Theme.translated
        case .warning: Theme.warning
        case .error: Theme.failure
        }
    }
}

extension View {
    /// Fills a pane with the window background so split panes read as one surface.
    func paneBackground() -> some View { background(Color(nsColor: .windowBackgroundColor)) }
}
