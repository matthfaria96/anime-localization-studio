import MediaKit
import StudioCore
import SwiftUI
import TranslationKit

/// First step of Legendar, in one short form: correct a subtitle of the video (optionally with
/// another one beside it) or make a new one in another language from an existing one.
struct SubtitleStartForm: View {
    @Bindable var workspace: WorkspaceModel
    @Environment(AppModel.self) private var app
    @State private var task: SubtitleTask = .edit
    @State private var editTrack: Int?
    @State private var reference: Int?
    @State private var baseTrack: Int?
    @State private var language = "pt-BR"
    @State private var autoTranslate = true

    /// Tag for “the subtitle file chosen from the disk”.
    private static let externalTag = -2

    private var textTracks: [MediaTrack] { workspace.subtitleTracks.filter { $0.textSubtitleExtension != nil } }
    private var hasExternal: Bool { workspace.project.externalSubtitlePath != nil }
    private var hasSource: Bool { !textTracks.isEmpty || hasExternal }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                Text("O que você vai editar?").font(.largeTitle.weight(.semibold))
                Panel {
                    choice(.edit, "Uma legenda do vídeo", "Corrigir texto, tempos e estilos. Ao gravar, ela entra no lugar da original.") { editOptions }
                    Divider()
                    choice(.translate, "Uma legenda nova", "Em outro idioma, a partir de uma legenda existente. Ao gravar, vira uma faixa nova.") { newOptions }
                }
                if !hasSource {
                    InlineMessage(kind: .info, text: "O vídeo não tem legenda de texto. Use um arquivo do disco, ou comece e transcreva o áudio (ou reconheça uma legenda em imagem) no próprio Mac.")
                }
                HStack {
                    Button("Usar um arquivo de legenda do disco…", systemImage: "doc.badge.plus") { workspace.openExternalSubtitle() }
                        .buttonStyle(.link)
                        .hint("Arquivo do disco", "Usa um arquivo ASS, SSA ou SRT como a legenda a editar ou como base.")
                    Spacer()
                    Button { start() } label: { Text("Começar").frame(minWidth: 90) }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .keyboardShortcut(.defaultAction)
                        .disabled(workspace.isBusy || (task == .translate && !hasSource))
                        .hint("Começar", task == .edit ? "Abre a legenda para editar." : (autoTranslate ? "Cria a legenda nova e já traduz todas as falas." : "Cria a legenda nova como cópia da base, para traduzir à mão."))
                }
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .paneBackground()
        .onAppear(perform: loadDefaults)
        .onChange(of: workspace.project.externalSubtitlePath) { loadDefaults() }
        // The tracks arrive after the page appears (each page loads the video again).
        .onChange(of: workspace.subtitleTracks.map(\.id)) { loadDefaults() }
    }

    private func choice<Options: View>(_ value: SubtitleTask, _ title: String, _ detail: String, @ViewBuilder options: () -> Options) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Button { task = value } label: {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                    Image(systemName: task == value ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(task == value ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline)
                        Text(detail).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if task == value {
                options().padding(.leading, 26).transition(.opacity)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .animation(.smooth(duration: 0.2), value: task)
    }

    private var editOptions: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Spacing.m, verticalSpacing: Theme.Spacing.s) {
            GridRow {
                Text("Legenda").foregroundStyle(.secondary)
                trackPicker(selection: $editTrack, includeNone: false)
                    .hint("Legenda a editar", "A faixa que você vai corrigir.")
            }
            GridRow {
                Text("Mostrar ao lado").foregroundStyle(.secondary)
                trackPicker(selection: $reference, includeNone: true, excluding: editTrack)
                    .hint("Mostrar ao lado", "Outra legenda do vídeo exibida ao lado, só para consulta (por exemplo a inglesa enquanto corrige a portuguesa). As falas são casadas pelo tempo.")
            }
        }
    }

    private var newOptions: some View {
        @Bindable var app = app
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Spacing.m, verticalSpacing: Theme.Spacing.s) {
            GridRow {
                Text("Idioma").foregroundStyle(.secondary)
                Picker("Idioma", selection: $language) {
                    ForEach(Languages.all, id: \.code) { Text($0.name).tag($0.code) }
                }
                .labelsHidden().fixedSize()
                .hint("Idioma da legenda nova", "O idioma da legenda que você vai criar. O nome e o idioma da faixa no vídeo saem daqui.")
            }
            GridRow {
                Text("A partir de").foregroundStyle(.secondary)
                trackPicker(selection: $baseTrack, includeNone: false)
                    .hint("Legenda base", "A legenda existente que serve de original. Ela fica ao lado, e a nova é casada fala a fala com ela.")
            }
            GridRow {
                Text("").gridCellUnsizedAxes(.horizontal)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Toggle("Traduzir automaticamente", isOn: $autoTranslate)
                        .hint("Traduzir automaticamente", "Ligado: ao começar, todas as falas são traduzidas, mantendo estilos, tempos e tags. Desligado: a legenda nova começa igual à base para você traduzir à mão.")
                    if autoTranslate {
                        Picker("com", selection: $app.settings.engine) {
                            ForEach(EngineChoice.allCases) { Text($0.label).tag($0) }
                        }
                        .fixedSize()
                        .hintVerbatim("Motor de tradução", app.settings.engine.summary)
                    }
                    if language == app.settings.targetLanguage, workspace.editor.translation != nil {
                        Text("Já existe um rascunho neste idioma (\(workspace.editor.translatedCount) de \(Plural.count(workspace.editor.translatableCount, "fala", "falas"))). Ele é continuado; só o que falta é traduzido.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func trackPicker(selection: Binding<Int?>, includeNone: Bool, excluding: Int? = nil) -> some View {
        Picker("Faixa", selection: selection) {
            if includeNone { Text("Nenhuma").tag(Int?.none) }
            ForEach(textTracks.filter { $0.id != excluding }) { track in
                Text("\(track.name ?? track.codec) · \(Languages.display(track.displayLanguage))").tag(Optional(track.id))
            }
            if hasExternal && !includeNone { Text("Arquivo do disco").tag(Optional(Self.externalTag)) }
        }
        .labelsHidden()
        .fixedSize()
        .disabled(!hasSource && !includeNone)
    }

    private func loadDefaults() {
        let current = hasExternal ? Self.externalTag : (workspace.project.sourceTrackID ?? textTracks.first?.id)
        task = workspace.project.subtitleTask ?? .edit
        editTrack = current
        baseTrack = current
        reference = workspace.project.referenceTrackID
        language = app.settings.targetLanguage
    }

    private func start() {
        let track = task == .edit ? editTrack : baseTrack
        workspace.startSubtitleWork(task: task, trackID: track == Self.externalTag ? nil : track,
                                    referenceID: reference, language: language, autoTranslate: autoTranslate)
    }
}
