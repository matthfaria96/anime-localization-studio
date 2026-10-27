import AppKit
import SwiftUI

/// (Same component as Wineup Player.) Balão de explicação que aparece ao parar o mouse sobre um controle: título curto e uma frase do que ele faz.
/// Fica numa janelinha própria (por cima dos painéis, que cortam o que vaza) e nunca recebe cliques.
struct HoverHint: ViewModifier {
    let title: String
    let detail: String

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside { HintWindow.shared.schedule(title: title, detail: detail) }
                else { HintWindow.shared.hide() }
            }
            .accessibilityHint(detail)
    }
}

extension View {
    /// Explica o controle ao passar o mouse (título em negrito e uma frase), traduzido.
    func hint(_ title: String.LocalizationValue, _ detail: String.LocalizationValue) -> some View {
        modifier(HoverHint(title: String(localized: title), detail: String(localized: detail)))
    }

    /// Igual a `hint`, para textos que já vêm traduzidos (ou são do usuário, como nomes de presets).
    func hintVerbatim(_ title: String, _ detail: String) -> some View { modifier(HoverHint(title: title, detail: detail)) }
}

@MainActor
final class HintWindow {
    static let shared = HintWindow()

    private static let delay: TimeInterval = 0.45
    private static let maxWidth: CGFloat = 260

    private var panel: NSPanel?
    private var pending: DispatchWorkItem?
    private var mouseDown: Any?

    func schedule(title: String, detail: String) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.show(title: title, detail: detail) }
        pending = work
        // Já mostrando outro balão: troca na hora, sem esperar de novo.
        DispatchQueue.main.asyncAfter(deadline: .now() + (panel?.isVisible == true ? 0.05 : Self.delay), execute: work)
    }

    func hide() {
        pending?.cancel()
        pending = nil
        panel?.orderOut(nil)
    }

    private func show(title: String, detail: String) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: HintBubble(title: title, detail: detail, width: nil))
        // Texto longo: quebra em linhas numa largura fixa (o tamanho ideal do SwiftUI é uma linha só).
        if host.fittingSize.width > Self.maxWidth + 24 {
            host.rootView = HintBubble(title: title, detail: detail, width: Self.maxWidth)
        }
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        panel.setFrame(frame(for: size), display: true)
        panel.orderFrontRegardless()
        // Qualquer clique esconde o balão (o menu que abrir não fica coberto).
        if mouseDown == nil {
            mouseDown = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { event in
                HintWindow.shared.hide()
                return event
            }
        }
    }

    /// Abaixo e à direita do ponteiro; perto da borda da tela, vira para o outro lado.
    private func frame(for size: NSSize) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }?.visibleFrame ?? .zero
        var origin = NSPoint(x: mouse.x + 12, y: mouse.y - size.height - 18)
        if origin.x + size.width > screen.maxX - 8 { origin.x = mouse.x - size.width - 12 }
        if origin.y < screen.minY + 8 { origin.y = mouse.y + 18 }
        origin.x = max(origin.x, screen.minX + 8)
        return NSRect(origin: origin, size: size)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        return panel
    }
}

private struct HintBubble: View {
    let title: String
    let detail: String
    let width: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 12, weight: .semibold))
            if !detail.isEmpty {
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: width, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
        .padding(1)
    }
}
