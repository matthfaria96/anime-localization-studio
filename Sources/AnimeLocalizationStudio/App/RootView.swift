import SwiftUI

/// One window, no sidebar: the start screen until a video is open, then the video's three
/// pages (Visão geral, Legendar, Dublar) switched at the top.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if let workspace = app.workspace {
                WorkspaceView(workspace: workspace, screen: app.screen).id(workspace.url)
            } else {
                WelcomeView()
            }
        }
        .alert(item: Bindable(app).alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .task {
            // Test hook for captures: ALS_SETTINGS=<tab> opens Settings on that tab (see SettingsView).
            if ProcessInfo.processInfo.environment["ALS_SETTINGS"] != nil { openSettings() }
            await app.refreshTools()
        }
    }
}

private struct WelcomeView: View {
    @Environment(AppModel.self) private var app
    @State private var isTargeted = false

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Spacing.xl) {
                VStack(spacing: Theme.Spacing.s) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                    Text("Anime Localization Studio").font(.largeTitle.weight(.semibold))
                    Text("Corrija, traduza e duble a legenda de um anime, série ou filme, direto no MKV. O vídeo nunca é recodificado e o arquivo original só muda se você pedir.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 560)
                }
                dropZone
                screens
                if !app.missingTools.isEmpty {
                    InlineMessage(kind: .warning, text: String(localized: "Faltam ferramentas: \(app.missingTools.map(\.tool.rawValue).joined(separator: ", ")). Veja Ajustes › Diagnóstico para instalar."))
                        .frame(maxWidth: 560)
                }
            }
            .padding(Theme.Spacing.xxl)
            .frame(maxWidth: .infinity)
        }
        .paneBackground()
        .navigationTitle("Anime Localization Studio")
    }

    private var dropZone: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: "film.stack").font(.system(size: 38)).foregroundStyle(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Text("Solte um vídeo aqui").font(.title3.weight(.semibold))
            Text("Um arquivo por vez: MKV, MP4 ou MOV.").foregroundStyle(.secondary)
            Button { app.presentOpenPanel() } label: {
                Label("Escolher vídeo…", systemImage: "folder").frame(minWidth: 150)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .keyboardShortcut("o", modifiers: .command)
            .hint("Escolher vídeo (⌘O)", "Abre um vídeo. As faixas são lidas sem alterar o arquivo.")
        }
        .padding(Theme.Spacing.xxl)
        .frame(maxWidth: 560)
        .background(isTargeted ? AnyShapeStyle(Color.accentColor.opacity(0.1)) : AnyShapeStyle(.background.secondary),
                    in: .rect(cornerRadius: Theme.Radius.large))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large)
            .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
        .dropDestination(for: URL.self) { urls, _ in app.openDropped(urls) } isTargeted: { isTargeted = $0 }
    }

    private var screens: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xl) {
            screen("film", "Visão geral", "Tamanho, codecs e faixas do vídeo. Escolha o áudio e a legenda padrão e extraia faixas.")
            screen("captions.bubble", "Legendar", "Corrija uma legenda, traduza para outro idioma ou crie uma ouvindo o áudio, preservando estilos e tags.")
            screen("waveform.and.person.filled", "Dublar", "Uma faixa de áudio dublada com a voz de cada personagem: pela ElevenLabs ou no próprio Mac.")
        }
        .frame(maxWidth: 760)
    }

    private func screen(_ icon: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint).frame(height: 28)
            Text(title).font(.headline)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
