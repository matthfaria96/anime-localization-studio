import MediaKit
import StudioCore
import SwiftUI
import TranslationKit

/// First step of Legendar, in one short form: correct a subtitle of the video (alone or with
/// another beside it), translate one, make one from the speech, start a blank one, or import a file.
struct SubtitleStartForm: View {
    @Bindable var workspace: WorkspaceModel
    @Environment(AppModel.self) private var app

    enum Choice: Hashable { case correct, translate, fromAudio, blank, importFile }

    @State private var choice: Choice = .correct
    @State private var editTrack: Int?
    @State private var reference: Int?
    @State private var baseTrack: Int?
    @State private var language = "pt-BR"
    @State private var autoTranslate = true
    @State private var audioTrack: Int?
    @State private var spokenLanguage = "ja-JP"
    @State private var identifySpeakers = true
    @State private var translateAfter = false
    @State private var blankLanguage = "pt-BR"
    /// The default choice follows what the video has until the person picks one.
    @State private var picked = false

    /// Tag for “the subtitle file chosen from the disk”.
    private static let externalTag = -2

    private var textTracks: [MediaTrack] { workspace.subtitleTracks.filter { $0.textSubtitleExtension != nil } }
    private var hasExternal: Bool { workspace.project.externalSubtitlePath != nil }
    private var hasSource: Bool { !textTracks.isEmpty || hasExternal }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                Text("O que você vai fazer?").font(.largeTitle.weight(.semibold))
                Panel {
                    option(.correct, "Corrigir uma legenda do vídeo", "Texto, tempos e estilos. Sozinha ou com outra ao lado para comparar.",
                           enabled: hasSource) { correctOptions }
                    Divider()
                    option(.translate, "Traduzir uma legenda", "Uma legenda nova em outro idioma, a partir de uma existente.",
                           enabled: hasSource) { translateOptions }
                    Divider()
                    option(.fromAudio, "Criar a partir do áudio", "Ouve o vídeo e escreve o que é dito, no tempo certo, no idioma falado. Depois pode traduzir.",
                           enabled: !workspace.audioTracks.isEmpty) { audioOptions }
                    Divider()
                    option(.blank, "Começar em branco", "Uma legenda vazia, só ela na tela, para escrever do zero.", enabled: true) { blankOptions }
                    Divider()
                    option(.importFile, "Importar um arquivo de legenda", "ASS, SSA ou SRT do disco, para corrigir. Para traduzir um arquivo, use “Traduzir uma legenda”.",
                           enabled: true) { EmptyView() }
                }
                HStack {
                    Spacer()
                    Button { start() } label: { Text(choice == .importFile ? "Escolher arquivo…" : "Começar").frame(minWidth: 110) }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(workspace.isBusy || !canStart)
                        .hintVerbatim("Começar", startHint)
                }
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .paneBackground()
        .onAppear(perform: loadDefaults)
        .onChange(of: workspace.project.externalSubtitlePath) { loadDefaults() }
        // The tracks arrive after the page appears (each page loads the video again).
        .onChange(of: workspace.subtitleTracks.map(\.id)) { loadDefaults() }
    }

    private var canStart: Bool {
        switch choice {
        case .correct, .translate: hasSource
        case .fromAudio: !workspace.audioTracks.isEmpty
        case .blank, .importFile: true
        }
    }

    private var startHint: String {
        switch choice {
        case .correct: reference == nil ? "Abre a legenda sozinha para corrigir." : "Abre a legenda com a outra ao lado."
        case .translate: autoTranslate ? "Cria a legenda nova e já traduz todas as falas." : "Cria a legenda nova como cópia da base, para traduzir à mão."
        case .fromAudio: translateAfter ? "Transcreve o áudio e depois traduz." : "Transcreve o áudio no idioma falado."
        case .blank: "Abre uma legenda vazia para escrever do zero."
        case .importFile: "Escolhe um arquivo de legenda do disco para corrigir."
        }
    }

    // MARK: Options

    private func option<Options: View>(_ value: Choice, _ title: String, _ detail: String, enabled: Bool,
                                       @ViewBuilder options: () -> Options) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Button { choice = value; picked = true } label: {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                    Image(systemName: choice == value ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(choice == value ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline)
                        Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.45)
            if choice == value {
                options().padding(.leading, 26).transition(.opacity)
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .animation(.smooth(duration: 0.2), value: choice)
    }

    private var correctOptions: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Spacing.m, verticalSpacing: Theme.Spacing.s) {
            GridRow {
                label("Legenda")
                trackPicker(selection: $editTrack, includeNone: false)
                    .hint("Legenda a corrigir", "A faixa (ou o arquivo importado) que você vai corrigir.")
            }
            GridRow {
                label("Comparar com")
                trackPicker(selection: $reference, includeNone: true, noneTitle: "Nenhuma (só ela na tela)", excluding: editTrack)
                    .hint("Comparar com", "Outra legenda exibida ao lado, só para consulta, casada pelo tempo. Escolha “Nenhuma” para ver só a que você edita.")
            }
        }
    }

    private var translateOptions: some View {
        @Bindable var app = app
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Spacing.m, verticalSpacing: Theme.Spacing.s) {
            GridRow {
                label("Para")
                languagePicker($language)
                    .hint("Idioma da legenda nova", "O nome e o idioma da faixa no vídeo saem daqui.")
            }
            GridRow {
                label("A partir de")
                HStack {
                    trackPicker(selection: $baseTrack, includeNone: false)
                    Button("Importar arquivo…") { workspace.openExternalSubtitle() }
                        .buttonStyle(.link)
                        .hint("Importar arquivo como base", "Usa um ASS, SSA ou SRT do disco como a legenda a traduzir.")
                }
                .hint("Legenda base", "A legenda que é traduzida. Ela fica ao lado, e a nova é casada fala a fala com ela.")
            }
            GridRow {
                Text("").gridCellUnsizedAxes(.horizontal)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack {
                        Toggle("Traduzir automaticamente com", isOn: $autoTranslate)
                        Picker("Motor", selection: $app.settings.engine) {
                            ForEach(EngineChoice.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        .disabled(!autoTranslate)
                    }
                    .hintVerbatim("Traduzir automaticamente", "Ligado: ao começar, todas as falas são traduzidas mantendo estilos, tempos e tags. Desligado: a legenda nova começa igual à base para traduzir à mão. \(app.settings.engine.summary)")
                    if language == app.settings.targetLanguage, workspace.editor.translation != nil {
                        Text("Já existe um rascunho neste idioma (\(workspace.editor.translatedCount) de \(Plural.count(workspace.editor.translatableCount, "fala", "falas"))). Ele é continuado; só o que falta é traduzido.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var audioOptions: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Spacing.m, verticalSpacing: Theme.Spacing.s) {
            if workspace.audioTracks.count > 1 {
                GridRow {
                    label("Áudio")
                    Picker("Áudio", selection: $audioTrack) {
                        ForEach(workspace.audioTracks) { Text(WorkspaceModel.describe($0)).tag(Optional($0.id)) }
                    }
                    .labelsHidden().fixedSize()
                    .hint("Áudio", "A faixa de áudio que será ouvida. Use a do idioma original.")
                }
            }
            GridRow {
                label("Idioma falado")
                Picker("Idioma falado", selection: $spokenLanguage) {
                    ForEach(TranscriptionLanguage.all, id: \.code) { Text($0.name).tag($0.code) }
                }
                .labelsHidden().fixedSize()
                .hint("Idioma falado", "O idioma em que os personagens falam no áudio. A legenda sai nesse idioma, no tempo de cada fala.")
            }
            GridRow {
                Text("").gridCellUnsizedAxes(.horizontal)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Toggle("Identificar quem fala", isOn: $identifySpeakers)
                        .hint("Identificar quem fala", "Marca “Falante 1”, “Falante 2”… em cada fala, pelo som da voz. Ajuda na dublagem. Tudo no Mac.")
                    HStack {
                        Toggle("Depois traduzir para", isOn: $translateAfter)
                        languagePicker($language).disabled(!translateAfter)
                    }
                    .hint("Depois traduzir", "Quando a transcrição terminar, cria a legenda traduzida a partir dela.")
                    Text("Tudo roda no Mac (reconhecimento de fala da Apple). Na primeira vez, o macOS pode pedir para baixar o modelo do idioma.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var blankOptions: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Spacing.m, verticalSpacing: Theme.Spacing.s) {
            GridRow {
                label("Idioma")
                languagePicker($blankLanguage)
                    .hint("Idioma", "O idioma da faixa que será criada no vídeo.")
            }
        }
    }

    private func label(_ text: String) -> some View { Text(text).foregroundStyle(.secondary) }

    private func languagePicker(_ selection: Binding<String>) -> some View {
        Picker("Idioma", selection: selection) {
            ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) }
        }
        .labelsHidden()
        .fixedSize()
    }

    private func trackPicker(selection: Binding<Int?>, includeNone: Bool, noneTitle: String = "Nenhuma", excluding: Int? = nil) -> some View {
        Picker("Faixa", selection: selection) {
            if includeNone { Text(noneTitle).tag(Int?.none) }
            ForEach(textTracks.filter { $0.id != excluding }) { track in
                Text("\(track.name ?? track.codec) · \(Languages.display(track.displayLanguage))").tag(Optional(track.id))
            }
            if hasExternal && !includeNone { Text("Arquivo importado").tag(Optional(Self.externalTag)) }
        }
        .labelsHidden()
        .fixedSize()
        .disabled(!hasSource && !includeNone)
    }

    // MARK: Start

    private func loadDefaults() {
        let current = hasExternal ? Self.externalTag : (workspace.project.sourceTrackID ?? textTracks.first?.id)
        if !picked {
            choice = hasSource ? .correct : workspace.audioTracks.isEmpty ? .blank : .fromAudio
        }
        editTrack = current
        baseTrack = current
        reference = workspace.project.referenceTrackID
        language = app.settings.targetLanguage
        blankLanguage = app.settings.targetLanguage
        audioTrack = workspace.dubAudioTrack?.id
    }

    private func start() {
        switch choice {
        case .correct:
            workspace.startSubtitleWork(task: .edit, trackID: editTrack == Self.externalTag ? nil : editTrack,
                                        referenceID: reference, language: app.settings.targetLanguage, autoTranslate: false)
        case .translate:
            workspace.startSubtitleWork(task: .translate, trackID: baseTrack == Self.externalTag ? nil : baseTrack,
                                        referenceID: nil, language: language, autoTranslate: autoTranslate)
        case .fromAudio:
            workspace.startFromAudio(spokenLanguage: spokenLanguage, audioTrackID: audioTrack,
                                     identifySpeakers: identifySpeakers, translateTo: translateAfter ? language : nil)
        case .blank:
            workspace.startBlankSubtitle(language: blankLanguage)
        case .importFile:
            workspace.startImportedSubtitle()
        }
    }
}
