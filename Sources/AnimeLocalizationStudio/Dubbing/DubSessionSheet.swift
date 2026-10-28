import DubbingKit
import MediaKit
import StudioCore
import SwiftUI

/// The dub as a guided window: what will happen and where it will be saved, then each step
/// while it runs, then where the result is (or what went wrong and what to do).
struct DubSessionSheet: View {
    @Bindable var workspace: WorkspaceModel
    @Binding var cast: VoiceCast
    let segmentCount: Int
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            switch workspace.dubSession?.phase ?? .confirm {
            case .confirm: confirm
            case .running: running
            case .done(let url, let report, let verification, let replaced): done(url, report, verification, replaced)
            case .failed(let message): failed(message)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 560)
        .modifier(SpeakerModelConsent(workspace: workspace))
        .interactiveDismissDisabled(isRunning)
    }

    private var isRunning: Bool { if case .running = workspace.dubSession?.phase { true } else { false } }
    private var online: Bool { workspace.dubsOnline }
    private var language: String { online ? app.settings.targetLanguage : workspace.dubLanguage }
    private var outputName: String {
        FileOps.uniqueURL(for: MuxPlan.defaultOutputURL(for: workspace.url, suffix: "\(language.uppercased()) DUB")).lastPathComponent
    }
    /// The local dub also adds the app's translation; a subtitle of the video is already there.
    private var addsSubtitle: Bool { !online && workspace.dubText?.isVideoTrack == false }

    // MARK: Before

    private var confirm: some View {
        @Bindable var app = app
        let speakers = cast.members.count
        return VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Text("Dublar “\(workspace.title)”").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                summary("waveform", "Áudio de base", workspace.dubAudioTrack.map(WorkspaceModel.describe) ?? "—")
                summary("globe", "Dublar para", Languages.name(for: language))
                if online {
                    summary("cloud", "Motor", "ElevenLabs: separa os personagens, traduz e dubla com a voz de cada um")
                    summary("person.wave.2", "Idioma falado", app.settings.dubbingSourceLanguage.map { code in
                        TranscriptionLanguage.all.first { $0.code == code }?.name ?? code } ?? "detectar automaticamente")
                } else {
                    summary("text.bubble", "Texto falado", "\(workspace.dubText?.isVideoTrack == true ? "legenda do vídeo" : "tradução feita no app"), \(Plural.count(segmentCount, "fala", "falas"))")
                    summary("waveform.badge.mic", "Vozes", app.settings.dubbingPerLineVoice ? "voz original, com a emoção de cada fala" : "voz original, uma amostra por personagem")
                    summary("slider.horizontal.3", "Modo", app.settings.dubbingMode.label)
                    summary("person.2", "Personagens", speakers > 0 ? Plural.count(speakers, "personagem", "personagens") : "identificados pelo áudio")
                }
            }
            if online {
                InlineMessage(kind: .info, text: workspace.project.remoteDub != nil
                              ? "Esta dublagem já foi enviada antes: o app retoma o trabalho na ElevenLabs, sem enviar nem cobrar de novo."
                              : "O áudio deste vídeo (sem a imagem) será enviado para a ElevenLabs e a dublagem usa créditos da sua conta. Leva alguns minutos; você pode continuar usando o app.")
            }
            if !online && !workspace.voiceModelsInstalled {
                InlineMessage(kind: .info, text: "Ao começar, o app baixa os modelos de voz uma única vez (\(ClonedVoiceSynthesizer.downloadSize); \(ClonedVoiceSynthesizer.modelCredits)). Tudo roda no Mac; o áudio não sai do computador.")
            }
            if !online && (workspace.cachedDubLines > 0 || workspace.dubStorageBytes > 0) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Toggle("Gerar tudo do zero", isOn: Binding(get: { workspace.dubSession?.regenerate ?? false },
                                                                set: { workspace.dubSession?.regenerate = $0 }))
                        .hint("Gerar tudo do zero", "Apaga as falas, as vozes e a música de fundo já geradas deste episódio e faz tudo de novo, inclusive a escolha das vozes. Use quando o resultado anterior saiu errado.")
                    Text(workspace.dubSession?.regenerate == true
                         ? "As falas, vozes e o fundo já preparados serão apagados e refeitos."
                         : "\(workspace.cachedDubLines) falas já geradas serão reaproveitadas; só o que falta ou mudou é gerado de novo.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !online {
                Text("Com a voz original, cada fala leva menos de um segundo no Mac; um episódio inteiro leva alguns minutos (mais na primeira vez, para baixar e preparar os modelos). Você pode continuar usando o app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text("Onde gravar").font(.headline)
                destination(false, "Criar um novo arquivo", "“\(outputName)”, na mesma pasta do original. O original não muda.")
                destination(true, "Gravar neste arquivo", "O áudio dublado\(addsSubtitle ? " e a legenda traduzida" : "") \(addsSubtitle ? "entram" : "entra") no arquivo aberto. Ele é regravado sem recodificar o vídeo, conferido, e o original vai para a Lixeira.")
            }
            HStack {
                Spacer()
                Button("Cancelar") { workspace.dubSession = nil }.keyboardShortcut(.cancelAction)
                Button(online ? "Enviar e dublar" : "Começar a dublagem") { workspace.startDub(cast: cast, undoManager: undoManager) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .hintVerbatim("Começar a dublagem", online
                        ? "Envia o áudio, espera a ElevenLabs dublar, baixa o resultado e grava onde você escolheu."
                        : "Identifica quem fala, prepara as vozes, gera todas as falas, mixa e grava onde você escolheu. Pode levar alguns minutos.")
            }
        }
    }

    private func summary(_ icon: String, _ title: String, _ value: String) -> some View {
        HStack {
            Label(title, systemImage: icon).frame(width: 140, alignment: .leading).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func destination(_ replace: Bool, _ title: String, _ detail: String) -> some View {
        let selected = (workspace.dubSession?.replaceOriginal ?? false) == replace
        return Button { workspace.dubSession?.replaceOriginal = replace } label: {
            HStack(alignment: .top, spacing: Theme.Spacing.s) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hintVerbatim(title, detail)
    }

    // MARK: During

    private var running: some View {
        let fraction = workspace.operation?.fraction ?? 0
        let current = WorkspaceModel.DubStage.at(fraction, online: online)
        let stages = WorkspaceModel.DubStage.stages(online: online)
        return VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Text("Dublando “\(workspace.title)”…").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                ForEach(stages, id: \.self) { stage in
                    HStack(spacing: Theme.Spacing.s) {
                        Group {
                            if stage.rawValue < current.rawValue { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.translated) }
                            else if stage == current { ProgressView().controlSize(.small) }
                            else { Image(systemName: "circle").foregroundStyle(.tertiary) }
                        }
                        .frame(width: 20)
                        Text(stage.title).foregroundStyle(stage.rawValue > current.rawValue ? .secondary : .primary)
                    }
                }
            }
            OperationProgress(message: workspace.operation?.message ?? "", fraction: fraction, onCancel: { workspace.cancelOperation() })
            Text("Você pode continuar usando o app; esta janela mostra quando terminar.").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: After

    private func done(_ url: URL, _ report: DubbingReport?, _ verification: VerificationReport, _ replaced: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Label("Dublagem pronta", systemImage: "checkmark.seal.fill").font(.title2.weight(.semibold)).foregroundStyle(Theme.translated)
            VStack(alignment: .leading, spacing: 4) {
                Text(replaced ? "Gravada no próprio arquivo:" : "Novo arquivo:").font(.callout.weight(.semibold))
                Text(url.lastPathComponent).font(.body.monospaced()).textSelection(.enabled)
                Text("Pasta: \(url.deletingLastPathComponent().path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if replaced { Text("A versão anterior está na Lixeira.").font(.caption).foregroundStyle(.secondary) }
            }
            Text(report.map { "\(Plural.count($0.synthesized + $0.reusedClips, "fala dublada", "falas dubladas")) · \($0.spedUp.count) aceleradas para caber · \($0.failed.count) sem voz. " } ?? ""
                 + "O áudio dublado é a faixa padrão; o original continua no arquivo.")
                .font(.callout)
            if !verification.passed { InlineMessage(kind: .warning, text: verification.failures.joined(separator: " ")) }
            HStack {
                Button("Mostrar no Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .hint("Mostrar no Finder", "Abre a pasta com o arquivo dublado selecionado.")
                if !replaced {
                    Button("Abrir no app", systemImage: "film") { workspace.dubSession = nil; app.open(url) }
                        .hint("Abrir no app", "Abre o arquivo dublado aqui para assistir e conferir.")
                }
                Spacer()
                Button("Fechar") { workspace.dubSession = nil }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func failed(_ message: String) -> some View {
        @Bindable var app = app
        return VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Label("A dublagem não terminou", systemImage: "exclamationmark.triangle.fill").font(.title2.weight(.semibold)).foregroundStyle(Theme.warning)
            Text(message).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            HStack {
                if online {
                    Button("Usar a voz do Mac") {
                        app.settings.dubbingEngine = .original
                        workspace.dubSession?.phase = .confirm
                    }
                    .hint("Usar a voz do Mac", "Troca para a dublagem gratuita no Mac, que fala a legenda traduzida.")
                }
                Spacer()
                Button("Tentar de novo") { workspace.dubSession?.phase = .confirm }
                Button("Fechar") { workspace.dubSession = nil }.keyboardShortcut(.defaultAction)
            }
        }
    }
}
