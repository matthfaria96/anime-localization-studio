import MediaKit
import StudioCore
import SwiftUI
import TranslationKit

/// How the Traduzir window opens (from the bar, or from “no subtitle” straight on the audio).
struct TranslateSheetStart: Identifiable {
    let id = UUID()
    var fromAudio = false
}

/// Traduzir: from a subtitle of the video or from its audio, into the output language. The
/// result is a new subtitle, edited with the one it came from beside it.
struct TranslateSheet: View {
    @Bindable var workspace: WorkspaceModel
    let start: TranslateSheetStart
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var fromAudio = false
    @State private var subtitle = -1
    @State private var audioTrack: Int?
    @State private var spoken = "ja-JP"
    @State private var identify = true
    @State private var language = "pt-BR"
    @State private var retranslateAll = false

    private var textTracks: [MediaTrack] { workspace.subtitleTracks.filter { $0.textSubtitleExtension != nil } }
    private var hasOpenSubtitle: Bool { workspace.project.externalSubtitlePath != nil }
    private var hasSubtitle: Bool { !textTracks.isEmpty || hasOpenSubtitle }
    private var hasAudio: Bool { !workspace.audioTracks.isEmpty }
    private var onlyWritesDown: Bool { fromAudio && Languages.base(spoken) == Languages.base(language) }

    /// A translation into this language from this subtitle already exists in the app.
    private var hasTranslation: Bool {
        guard !fromAudio, let url = workspace.store.translationURL(for: workspace.project, language: language),
              FileManager.default.fileExists(atPath: url.path) else { return false }
        return subtitle == -2 ? hasOpenSubtitle : subtitle == workspace.project.sourceTrackID && !hasOpenSubtitle
    }

    var body: some View {
        @Bindable var app = app
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Text("Traduzir").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                Text("Traduzir de").font(.headline)
                ChoiceRow(title: "Legenda do vídeo", selected: !fromAudio,
                          disabledReason: hasSubtitle ? nil : "O vídeo não tem legenda de texto.", action: { fromAudio = false }) {
                    Picker("Legenda", selection: $subtitle) {
                        if hasOpenSubtitle { Text("A legenda aberta (nova ou importada)").tag(-2) }
                        ForEach(textTracks) { Text("\($0.name ?? $0.codec) · \(Languages.display($0.displayLanguage))").tag($0.id) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .hint("Legenda de origem", "A legenda que é traduzida, com estilos, tempos e tags preservados.")
                }
                ChoiceRow(title: "Áudio do vídeo", selected: fromAudio,
                          disabledReason: hasAudio ? nil : "O vídeo não tem áudio.", action: { fromAudio = true }) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        HStack {
                            Picker("Idioma falado", selection: $spoken) {
                                ForEach(TranscriptionLanguage.all, id: \.code) { Text($0.name).tag($0.code) }
                            }
                            .fixedSize()
                            .hint("Idioma falado", "O idioma em que os personagens falam. O reconhecimento de fala do Mac precisa saber qual é.")
                            if workspace.audioTracks.count > 1 {
                                Picker("Áudio", selection: $audioTrack) {
                                    ForEach(workspace.audioTracks) { Text(WorkspaceModel.describe($0)).tag(Optional($0.id)) }
                                }
                                .labelsHidden()
                                .fixedSize()
                                .hint("Faixa de áudio", "A faixa que é ouvida. Use a do idioma original.")
                            }
                        }
                        Toggle("Separar as vozes para a dublagem", isOn: $identify)
                            .hint("Separar as vozes", "Descobre pelo som quem fala cada fala (Voz 1, Voz 2…), para a dublagem dar uma voz a cada um. Fica guardado no app; a legenda sai sem nomes.")
                        Text("O app ouve o vídeo e escreve o que é dito, no tempo de cada fala, tudo no Mac.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Spacing.m, verticalSpacing: Theme.Spacing.m) {
                GridRow {
                    Text("Idioma de saída").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Picker("Idioma de saída", selection: $language) {
                            ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .hint("Idioma de saída", "O idioma da legenda nova.")
                        if onlyWritesDown {
                            Text("É o idioma falado: o app só escreve o que é dito, sem traduzir.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !onlyWritesDown {
                    GridRow {
                        Text("Motor").foregroundStyle(.secondary)
                        Picker("Motor", selection: $app.settings.engine) {
                            ForEach(EngineChoice.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .hintVerbatim("Motor de tradução", app.settings.engine.summary)
                    }
                    GridRow {
                        Text("Glossário").foregroundStyle(.secondary)
                        HStack {
                            Picker("Glossário", selection: Binding(get: { workspace.project.seriesID }, set: { workspace.assignSeries($0) })) {
                                Text("Nenhum").tag(UUID?.none)
                                ForEach(app.series) { Text($0.name).tag(Optional($0.id)) }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .hint("Glossário da série", "Nomes, golpes e lugares que devem sair sempre iguais. O elenco de vozes da série também é usado na dublagem.")
                            Button("Editar…") { workspace.showSeries = true }
                                .buttonStyle(.link)
                                .hint("Editar glossários", "Termos que devem ser traduzidos sempre do mesmo jeito e notas de estilo da série.")
                        }
                    }
                }
            }
            if hasTranslation {
                Toggle("Traduzir tudo de novo (a tradução que já existe para este idioma é substituída; uma cópia fica no projeto)", isOn: $retranslateAll)
                    .font(.callout)
                    .hint("Traduzir tudo de novo", "Desligado: abre a tradução que já existe e traduz só as falas que faltam. Ligado: refaz todas.")
            }
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(onlyWritesDown ? "Criar legenda" : "Traduzir") {
                    let source: TranslationRequest.Source = fromAudio
                        ? .audio(track: audioTrack, spokenLanguage: spoken, identifySpeakers: identify)
                        : .subtitle(subtitle)
                    dismiss()
                    workspace.requestTranslation(TranslationRequest(source: source, language: language, retranslateAll: retranslateAll))
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(fromAudio ? !hasAudio : !hasSubtitle)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 520)
        .onAppear(perform: setUp)
        .sheet(isPresented: $workspace.showSeries) {
            VStack(spacing: 0) {
                SeriesView().frame(minWidth: 760, minHeight: 480)
                Divider()
                HStack { Spacer(); Button("Fechar") { workspace.showSeries = false }.keyboardShortcut(.defaultAction) }
                    .padding(Theme.Spacing.m)
            }
        }
    }

    private func setUp() {
        fromAudio = (start.fromAudio || !hasSubtitle) && hasAudio
        subtitle = hasOpenSubtitle ? -2 : (textTracks.first { $0.id == workspace.project.sourceTrackID } ?? textTracks.first)?.id ?? -1
        audioTrack = workspace.dubAudioTrack?.id
        language = app.settings.targetLanguage
        // The spoken language from the audio track, when it says.
        if let track = workspace.dubAudioTrack {
            let base = Languages.base(EpisodeWorkflow.language(of: track))
            if let match = TranscriptionLanguage.all.first(where: { Languages.base($0.code) == base }) { spoken = match.code }
        }
    }
}
