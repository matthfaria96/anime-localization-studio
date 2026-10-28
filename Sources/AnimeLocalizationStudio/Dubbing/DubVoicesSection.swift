import AVFoundation
import DubbingKit
import StudioCore
import SwiftUI

/// Settings of the Mac's own voice: emotion per line, how the voices are mixed, and the
/// characters (who speaks, listen to the original and to the dub). Collapsed by default.
struct DubVoicesSection: View {
    @Bindable var workspace: WorkspaceModel
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    @State private var sampleState: [UUID: String] = [:]
    @State private var audioPlayer: AVAudioPlayer?

    private var segments: [DubSegment] { workspace.dubSegments }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            enginePanel
            castPanel
        }
    }

    private var enginePanel: some View {
        @Bindable var app = app
        return Panel {
            SectionLabel("Voz", systemImage: "waveform.badge.mic")
            Toggle(isOn: $app.settings.dubbingPerLineVoice) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voz e emoção de cada fala")
                    Text(app.settings.dubbingPerLineVoice
                         ? "Cada fala é recriada a partir do próprio trecho original: mesma voz e mesma emoção (grito, sussurro…). Falas com menos de 1,5 s usam a amostra do personagem."
                         : "Uma amostra de ~12 s por personagem: voz estável, mas sem a emoção de cada fala.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .hint("Voz e emoção de cada fala", "Ligado (recomendado): o trecho japonês de cada fala, sem a música, serve de referência para a mesma fala dublada. Desligado: uma amostra fixa por personagem.")
            SectionLabel("Modo", systemImage: "slider.horizontal.3")
            HStack(spacing: Theme.Spacing.m) {
                OptionCard(title: "Substituir falas", systemImage: "person.2.slash",
                           detail: "As vozes originais saem e as novas entram no lugar, com a música e os efeitos.",
                           selected: app.settings.dubbingMode == .replaceDialogue) { app.settings.dubbingMode = .replaceDialogue }
                    .hint("Substituir falas", "Como uma dublagem de TV: o app separa as vozes originais da música e dos efeitos, tira as vozes e coloca as dubladas no lugar. A separação é feita no Mac e é aproximada: em cenas com muita música podem sobrar restos da voz original.")
                OptionCard(title: "Voice-over", systemImage: "person.2.wave.2",
                           detail: "A voz nova fala por cima; o áudio original abaixa enquanto ela fala.",
                           selected: app.settings.dubbingMode == .voiceOver) { app.settings.dubbingMode = .voiceOver }
                    .hint("Voice-over", "Como em documentários: o áudio original continua, só que mais baixo enquanto a voz dublada fala por cima.")
            }
        }
    }

    // MARK: Cast

    private var castPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack {
                SectionLabel("Personagens", systemImage: "person.2")
                if !workspace.cast.members.isEmpty {
                    Text(workspace.hasAutoSpeakers ? "identificados pelo áudio (guardados no app, fora da legenda)" : "do campo Personagem da legenda")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if workspace.hasAutoSpeakers || workspace.cast.members.contains(where: { $0.name.hasPrefix("Falante ") || $0.name.hasPrefix("Voz ") }) {
                    Button("Limpar", systemImage: "xmark.circle") { workspace.clearIdentifiedSpeakers(undoManager: undoManager) }
                        .disabled(workspace.isBusy)
                        .hint("Limpar personagens identificados", "Esquece as “Voz 1, Voz 2…” achadas pelo áudio (e tira da legenda os “Falante N” que versões antigas gravavam). A próxima dublagem identifica de novo, sem gravar nada na legenda.")
                }
                Button("Identificar falantes no áudio", systemImage: "person.wave.2") { workspace.identifyDubSpeakers() }
                    .disabled(workspace.isBusy || workspace.dubText == nil || workspace.audioTracks.isEmpty)
                    .hint("Identificar falantes no áudio", "Descobre pelo áudio quem fala em cada linha sem personagem (“Voz 1”, “Voz 2”…), para dar uma voz a cada um. Fica guardado no app: a legenda não muda. A dublagem faz isso sozinha quando precisa.")
            }
            if workspace.cast.members.isEmpty {
                Text(workspace.editor.hasDocument
                     ? "A legenda ainda não diz quem fala. Ao dublar, o app identifica os falantes pelo áudio; ou clique em “Identificar falantes no áudio” para ver e renomear antes."
                     : "Abra uma legenda para começar.")
                    .foregroundStyle(.secondary)
            }
            ForEach($workspace.cast.members) { $member in castRow($member) }
        }
    }

    private func castRow(_ member: Binding<CastMember>) -> some View {
        let name = member.wrappedValue.name
        let lines = segments.filter { workspace.cast.member(for: $0.speaker)?.id == member.wrappedValue.id }
        return HStack(spacing: Theme.Spacing.m) {
            Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.tint.opacity(0.8))
            VStack(alignment: .leading, spacing: 2) {
                CastNameField(name: name) { newName in
                    workspace.renameCastMember(member.wrappedValue.id, to: newName, undoManager: undoManager)
                }
                Text(Plural.count(lines.count, "fala", "falas")).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 170, alignment: .leading)
            Button("Ouvir original", systemImage: "ear") { Task { await playOriginal(name) } }
                .disabled(workspace.isBusy && workspace.voiceSamples.isEmpty)
                .hint("Ouvir a voz original", "Toca um trecho da voz deste personagem no episódio, sem a música, para você saber quem é.")
            Stepper(value: member.speed, in: 0.7...1.5, step: 0.05) {
                Text("Velocidade \(member.wrappedValue.speed, format: .number.precision(.fractionLength(2)))").monospacedDigit()
            }
            .hint("Velocidade", "Deixa as falas deste personagem mais lentas (abaixo de 1) ou mais rápidas (acima de 1) na dublagem. Falas que não cabem no tempo ainda são aceleradas um pouco.")
            Spacer()
            Button("Ouvir dublada", systemImage: "play.circle") { Task { await sample(member.wrappedValue, line: lines.first?.text) } }
                .disabled(member.wrappedValue.voiceID == nil)
                .hintVerbatim("Ouvir dublada", "Toca uma fala deste personagem em \(Languages.name(for: workspace.dubLanguage)) com a voz preparada na última dublagem.")
            if let state = sampleState[member.wrappedValue.id] { Text(state).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        .padding(Theme.Spacing.s)
        .background(.background.secondary, in: .rect(cornerRadius: Theme.Radius.medium))
    }

    // MARK: Listening

    private func playOriginal(_ speaker: String) async {
        if workspace.voiceSamples[speaker] == nil { await workspace.prepareVoiceSamples() }
        guard let url = workspace.voiceSamples[speaker], let data = try? Data(contentsOf: url) else { return }
        audioPlayer = try? AVAudioPlayer(data: data)
        audioPlayer?.play()
    }

    private func sample(_ member: CastMember, line: String?) async {
        guard let voice = member.voiceID else { return }
        sampleState[member.id] = "Gerando…"
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("als-sample-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            guard let line else { sampleState[member.id] = "Este personagem não tem falas no texto escolhido."; return }
            try await app.settings.makeSynthesizer(paths: app.paths, language: workspace.dubLanguage).synthesize(line, voice: voice, to: file)
            audioPlayer = try AVAudioPlayer(data: Data(contentsOf: file))
            audioPlayer?.play()
            sampleState[member.id] = nil
        } catch {
            sampleState[member.id] = error.localizedDescription
        }
    }
}

/// Character name that renames every line of that character when edited (Return to apply).
private struct CastNameField: View {
    let name: String
    let rename: (String) -> Void
    @State private var draft = ""

    var body: some View {
        TextField("Personagem", text: $draft)
            .textFieldStyle(.plain)
            .font(.headline)
            .onAppear { draft = name }
            .onChange(of: name) { draft = name }
            .onSubmit { if draft != name { rename(draft) } }
            .hint("Nome do personagem", "Digite o nome e aperte Return (ex.: Voz 1 → Kirito). Todas as falas dessa voz passam a usar o nome; a legenda do vídeo não muda.")
    }
}
