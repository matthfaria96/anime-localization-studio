import DubbingKit
import MediaKit
import StudioCore
import SwiftUI
import TranslationKit

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var app
    @State private var engines: [(EngineChoice, EngineAvailability)] = []
    @State private var voiceStudio: String?
    @State private var checking = false

    var body: some View {
        Form {
            Section {
                ForEach(app.toolStatuses) { status in ToolRow(status: status) }
                if app.toolStatuses.isEmpty { ProgressView() }
            } header: {
                Text("Ferramentas de mídia")
            } footer: {
                Text("O app procura em /opt/homebrew/bin, /usr/local/bin, /opt/local/bin e no MKVToolNix.app. Outro caminho pode ser definido em Ajustes › Ferramentas.")
            }
            Section("Motores de tradução") {
                ForEach(engines, id: \.0) { choice, availability in
                    LabeledContent {
                        availabilityLabel(availability)
                    } label: {
                        Text(choice.label)
                        Text(choice.summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if engines.isEmpty { ProgressView() }
            }
            Section("Dublagem") {
                LabeledContent("VoiceStudio (\(app.settings.voiceStudioURL.absoluteString))") {
                    if let voiceStudio {
                        Label(voiceStudio, systemImage: voiceStudio == "Conectado" ? "checkmark.circle.fill" : "minus.circle")
                            .foregroundStyle(voiceStudio == "Conectado" ? Theme.translated : .secondary)
                    } else { ProgressView().controlSize(.small) }
                }
                Text("O VoiceStudio é um app separado (AGPL-3.0) que roda os modelos de voz no Apple silicon via Metal/MLX. Instale-o em voicestudio.sh; este app só conversa com a API local dele.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Dados do app") {
                LabeledContent("Projetos, séries e fila") { pathButton(app.paths.root) }
                LabeledContent("Pré-visualizações em cache") {
                    HStack {
                        pathButton(app.paths.previews)
                        Button("Limpar") { try? PreviewProxy(tools: app.tools, cacheDirectory: app.paths.previews).clearCache() }
                    }
                }
                LabeledContent("Registros") { pathButton(app.paths.logs) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Diagnóstico")
        .toolbar {
            Button("Verificar de novo", systemImage: "arrow.clockwise") { Task { await check() } }.disabled(checking)
        }
        .task { await check() }
    }

    private func check() async {
        checking = true
        defer { checking = false }
        await app.refreshTools()
        let settings = app.settings
        let source = settings.sourceLanguage ?? "en"
        var results: [(EngineChoice, EngineAvailability)] = []
        for choice in EngineChoice.allCases {
            var copy = settings
            copy.engine = choice
            let availability = await copy.makeEngine(apiKey: AppModel.apiKey(for: copy)).availability(source: source, target: settings.targetLanguage)
            results.append((choice, availability))
        }
        engines = results
        do {
            _ = try await VoiceStudioClient(baseURL: settings.voiceStudioURL).capabilities()
            voiceStudio = "Conectado"
        } catch {
            voiceStudio = "Não está em execução"
        }
    }

    @ViewBuilder
    private func availabilityLabel(_ availability: EngineAvailability) -> some View {
        switch availability {
        case .available: Label("Disponível", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.translated)
        case .needsSetup(let m): Label(m, systemImage: "exclamationmark.circle").foregroundStyle(Theme.warning).font(.caption).frame(maxWidth: 280, alignment: .trailing)
        case .unavailable(let m): Label(m, systemImage: "xmark.circle").foregroundStyle(.secondary).font(.caption).frame(maxWidth: 280, alignment: .trailing)
        }
    }

    private func pathButton(_ url: URL) -> some View {
        Button("Mostrar no Finder") {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        .buttonStyle(.link)
    }
}

private struct ToolRow: View {
    let status: ToolStatus

    var body: some View {
        LabeledContent {
            if status.isAvailable {
                Label(status.version ?? "OK", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.translated).monospacedDigit()
            } else {
                HStack {
                    Text(status.tool.installCommand).font(.callout.monospaced()).textSelection(.enabled)
                    Button("Copiar", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(status.tool.installCommand, forType: .string)
                    }
                    .labelStyle(.iconOnly)
                    .help("Copiar o comando de instalação")
                }
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Text(status.tool.rawValue).font(.body.monospaced())
                Tag(text: status.tool.package)
            }
            Text(status.isAvailable ? (status.url?.path ?? "") : status.tool.purpose).font(.caption).foregroundStyle(.secondary)
        }
    }
}
