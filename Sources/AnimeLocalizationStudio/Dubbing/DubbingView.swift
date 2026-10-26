import AVFoundation
import DubbingKit
import MediaKit
import StudioCore
import SubtitleKit
import SwiftUI

/// Voice casting and the voice-over dub of the episode. Voices come from macOS (basic, always
/// available) or from VoiceStudio (natural and cloned voices, installed separately).
struct DubbingView: View {
    @Bindable var workspace: WorkspaceModel
    @Environment(AppModel.self) private var app
    @State private var connection: Connection = .checking
    @State private var studioVoices: [VoiceStudioClient.Voice] = []
    @State private var cast = VoiceCast()
    @State private var sampleState: [UUID: String] = [:]
    @State private var audioPlayer: AVAudioPlayer?

    enum Connection: Equatable { case checking, connected, offline(String) }

    private struct VoiceOption: Hashable, Identifiable { let id: String; let name: String }

    private var voiceOptions: [VoiceOption] {
        switch app.settings.dubbingEngine {
        case .system:
            let prefix = String(app.settings.targetLanguage.prefix(2))
            return AVSpeechSynthesisVoice.speechVoices()
                .filter { $0.language.hasPrefix(prefix) }
                .map { VoiceOption(id: $0.name, name: "\($0.name) (\($0.language))") }
        case .voiceStudio:
            return studioVoices.map { VoiceOption(id: $0.voice_id, name: $0.name) }
        }
    }

    private var engineReady: Bool { app.settings.dubbingEngine == .system || connection == .connected }

    private var segments: [DubSegment] {
        guard let document = workspace.editor.translation else { return [] }
        return DubbingPlan.segments(from: document)
    }

    var body: some View {
        @Bindable var app = app
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Dublagem").font(.largeTitle.weight(.semibold))
                    Text("Escolha uma voz para cada personagem e gere uma faixa de áudio em português sobre o áudio original (voice-over). O elenco fica salvo na série e vale para os próximos episódios.")
                        .foregroundStyle(.secondary)
                }
                if let operation = workspace.operation {
                    OperationProgress(message: operation.message, fraction: operation.fraction) { workspace.cancelOperation() }
                }
                if let notice = workspace.notice { InlineMessage(kind: notice.kind, text: notice.text) }
                enginePanel
                castPanel
                dubPanel
                if let dub = workspace.lastDub { resultPanel(dub) }
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
        }
        .paneBackground()
        .task {
            cast = workspace.loadCast()
            rebuildCast()
            await connect()
        }
        .onChange(of: app.settings.dubbingEngine) { Task { await connect() } }
        .onChange(of: workspace.editor.rows.count) { rebuildCast() }
        .onChange(of: cast) { _, new in workspace.saveCast(new) }
    }

    // MARK: Panels

    private var enginePanel: some View {
        @Bindable var app = app
        return Panel {
            HStack(spacing: Theme.Spacing.m) {
                Image(systemName: "waveform.badge.mic").font(.title).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Picker("Motor de voz", selection: $app.settings.dubbingEngine) {
                        ForEach(DubbingEngineChoice.allCases) { Text($0.label).tag($0) }
                    }
                    .fixedSize()
                    Text(engineStatus).font(.callout).foregroundStyle(engineReady ? Theme.translated : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if app.settings.dubbingEngine == .voiceStudio {
                    Button("Conectar de novo") { Task { await connect() } }
                }
            }
            if app.settings.dubbingEngine == .system {
                Text("As vozes do macOS são robóticas: servem para rascunho, revisão de tempo e testes. Para vozes naturais ou clonadas, instale o VoiceStudio (voicestudio.sh, Apple silicon com Metal). Mais vozes do sistema: Ajustes do Sistema › Acessibilidade › Conteúdo Falado.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if case .offline = connection {
                Text("Instale o VoiceStudio e deixe-o aberto. Ele só baixa modelos com a sua confirmação, mostrando tamanho e licença de cada um. Clone vozes apenas com permissão de quem fala.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var engineStatus: String {
        switch app.settings.dubbingEngine {
        case .system: return "\(voiceOptions.count) vozes do sistema em \(app.settings.targetLanguage) neste Mac"
        case .voiceStudio:
            switch connection {
            case .checking: return "Procurando o VoiceStudio em \(app.settings.voiceStudioURL.absoluteString)…"
            case .connected: return "Conectado · \(studioVoices.count) vozes"
            case .offline(let message): return message
            }
        }
    }

    private var castPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack {
                SectionLabel("Elenco", systemImage: "person.2")
                Spacer()
                Picker("Voz para falas sem personagem", selection: Binding(get: { app.settings.dubbingDefaultVoice }, set: { app.settings.dubbingDefaultVoice = $0 })) {
                    Text("Nenhuma (pular)").tag(String?.none)
                    ForEach(voiceOptions) { Text($0.name).tag(Optional($0.id)) }
                }
                .fixedSize()
                .controlSize(.small)
            }
            if cast.members.isEmpty {
                Text(workspace.editor.translation == nil
                     ? "Traduza o episódio primeiro: o elenco vem dos personagens (campo Ator/Name do ASS) das falas traduzidas."
                     : "A legenda não indica personagens. As falas usarão a voz padrão acima.")
                    .foregroundStyle(.secondary)
            }
            ForEach($cast.members) { $member in castRow($member) }
        }
    }

    private func castRow(_ member: Binding<CastMember>) -> some View {
        let lines = segments.filter { $0.speaker == member.wrappedValue.name }
        return HStack(spacing: Theme.Spacing.m) {
            Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.tint.opacity(0.8))
            VStack(alignment: .leading, spacing: 2) {
                Text(member.wrappedValue.name).font(.headline)
                Text("\(lines.count) falas").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 150, alignment: .leading)
            Picker("Voz", selection: member.voiceID) {
                Text("Sem voz").tag(String?.none)
                ForEach(voiceOptions) { Text($0.name).tag(Optional($0.id)) }
            }
            .frame(maxWidth: 230)
            .disabled(!engineReady)
            if app.settings.dubbingEngine == .voiceStudio {
                TextField("Estilo (ex.: jovem, enérgico)", text: member.style)
            } else {
                Spacer()
            }
            Stepper(value: member.speed, in: 0.7...1.5, step: 0.05) {
                Text(member.wrappedValue.speed, format: .number.precision(.fractionLength(2))).monospacedDigit().frame(width: 34)
            }
            .help("Velocidade da fala")
            Button("Ouvir", systemImage: "play.circle") { Task { await sample(member.wrappedValue, line: lines.first?.text) } }
                .disabled(member.wrappedValue.voiceID == nil || !engineReady)
            if let state = sampleState[member.wrappedValue.id] { Text(state).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        .padding(Theme.Spacing.s)
        .background(.background.secondary, in: .rect(cornerRadius: Theme.Radius.medium))
    }

    private var dubPanel: some View {
        Panel {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dublar episódio inteiro").font(.headline)
                    Text("\(segments.count) falas com tempo definido · \(segments.filter(\.isLikelyTooLong).count) provavelmente longas para o tempo (serão aceleradas até \(Int((app.settings.dubbingMaxSpeedup - 1) * 100))%)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    workspace.dubEpisode(cast: cast)
                } label: {
                    Label("Dublar episódio inteiro", systemImage: "waveform")
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .disabled(segments.isEmpty || !engineReady || workspace.isBusy)
            }
            Text("Resultado: um novo “Nome [PT-BR DUB].mkv” com o áudio dublado e a legenda em português, mantendo o áudio, as legendas e as fontes originais. O original não é alterado.")
                .font(.caption).foregroundStyle(.secondary)
            InlineMessage(kind: .info, text: "Modo disponível: voice-over (a voz nova fala por cima, com o original abaixado). “Substituir falas” precisa separar a voz da trilha (Demucs/BS-RoFormer) e ainda não está implementado.")
        }
    }

    private func resultPanel(_ dub: (url: URL, report: DubbingReport, verification: VerificationReport)) -> some View {
        Panel {
            HStack {
                SectionLabel("Última dublagem", systemImage: "checkmark.seal")
                Spacer()
                Button("Mostrar no Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([dub.url]) }
                    .buttonStyle(.link)
            }
            let r = dub.report
            Text("\(r.synthesized) vozes geradas, \(r.reusedClips) reaproveitadas · \(r.spedUp.count) aceleradas · \(r.overflowing.count) ainda longas · \(r.delayed.count) atrasadas para não sobrepor · \(r.failed.count) sem voz")
                .font(.callout)
            let problems = r.problemLines.sorted()
            if !problems.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Para revisar").font(.caption.weight(.semibold))
                    ForEach(problems.prefix(12), id: \.self) { id in
                        Button("Fala \(id + 1): \(segments.first { $0.id == id }?.text ?? "")") {
                            workspace.select(id, seek: true)
                        }
                        .buttonStyle(.link)
                        .lineLimit(1)
                    }
                }
            }
            VerificationList(report: dub.verification)
        }
    }

    // MARK: Actions

    private func connect() async {
        guard app.settings.dubbingEngine == .voiceStudio else { connection = .connected; return }
        connection = .checking
        let client = VoiceStudioClient(baseURL: app.settings.voiceStudioURL)
        do {
            _ = try await client.capabilities()
            studioVoices = try await client.voices()
            connection = .connected
        } catch {
            connection = .offline(error.localizedDescription)
        }
    }

    private func rebuildCast() {
        cast.addMissing(from: DubbingPlan.speakers(in: segments).filter { $0 != "Desconhecido" })
    }

    private func sample(_ member: CastMember, line: String?) async {
        guard let voice = member.voiceID else { return }
        sampleState[member.id] = "Gerando…"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("als-sample-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try await app.settings.makeSynthesizer().synthesize(line ?? "Olá! Esta é uma amostra da minha voz.", voice: voice,
                                                                 style: member.style.isEmpty ? nil : member.style, speed: member.speed, to: file)
            audioPlayer = try AVAudioPlayer(data: Data(contentsOf: file))
            audioPlayer?.play()
            sampleState[member.id] = nil
        } catch {
            sampleState[member.id] = error.localizedDescription
        }
    }
}
