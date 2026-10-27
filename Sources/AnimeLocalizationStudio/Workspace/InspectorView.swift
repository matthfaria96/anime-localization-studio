import MediaKit
import StudioCore
import SwiftUI
import TranslationKit

/// Right column of Legendar. Its sections follow the chosen task: which subtitle is edited and
/// how to save it back, or which subtitle is the base, the translation and the new track.
struct InspectorView: View {
    @Bindable var workspace: WorkspaceModel
    let requestTranslate: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager

    private var isEditing: Bool { workspace.isEditingOriginal }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                if let operation = workspace.operation {
                    let cancel: (() -> Void)? = operation.kind == .loading ? nil : { workspace.cancelOperation() }
                    OperationProgress(message: operation.message, fraction: operation.fraction, onCancel: cancel)
                }
                if let notice = workspace.notice {
                    InlineMessage(kind: notice.kind, text: notice.text)
                    if let action = workspace.noticeAction { Button(action.title, action: action.run).buttonStyle(.link) }
                }
                taskHeader
                baseSection
                if isEditing {
                    saveEditedSection
                } else {
                    translationSection
                    muxSection
                }
            }
            .padding(Theme.Spacing.l)
            .animation(.smooth(duration: 0.25), value: workspace.operation)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: Task

    private var taskHeader: some View {
        HStack(alignment: .top) {
            Label(isEditing ? "Editando uma legenda" : "Criando uma tradução", systemImage: isEditing ? "pencil.line" : "translate")
                .font(.headline)
            Spacer()
            Button("Trocar") { workspace.chooseSubtitleTask(nil) }
                .controlSize(.small)
                .disabled(workspace.isBusy)
                .hint("Trocar de tarefa", "Volta à escolha entre editar uma legenda existente e criar uma tradução. Nada do que você fez é perdido.")
        }
    }

    // MARK: Which subtitle

    private var baseSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionLabel(isEditing ? "Legenda que você está editando" : "Legenda base (o original)", systemImage: "captions.bubble")
            ForEach(workspace.subtitleTracks) { track in
                ChoiceRow(title: track.name ?? track.displayLanguage, detail: "\(track.displayLanguage.uppercased()) · \(track.codec)\(track.isBitmapSubtitle ? " · imagem" : "")",
                          selected: track.id == workspace.project.sourceTrackID && workspace.project.externalSubtitlePath == nil,
                          enabled: track.textSubtitleExtension != nil && !workspace.isBusy) {
                    workspace.selectSourceTrack(track.id)
                }
                .hintVerbatim(track.name ?? track.displayLanguage, track.textSubtitleExtension != nil
                              ? (isEditing ? "Edita esta faixa. Ao salvar, a versão corrigida entra no lugar dela." : "Usa esta faixa como o texto a traduzir.")
                              : "Legenda em imagem: para editar, transforme em texto com “Reconhecer texto (OCR)” no editor vazio.")
            }
            if workspace.project.externalSubtitlePath != nil {
                ChoiceRow(title: "Arquivo externo", detail: workspace.project.sourceFormat?.fileExtension.uppercased() ?? "", selected: true, enabled: true) {}
            }
            Button("Abrir um arquivo de legenda…", systemImage: "doc.badge.plus") { workspace.openExternalSubtitle() }
                .buttonStyle(.link)
                .disabled(workspace.isBusy)
                .hint("Abrir um arquivo de legenda", "Usa um arquivo ASS, SSA ou SRT do disco no lugar das faixas do arquivo.")
        }
    }

    // MARK: Saving an edited subtitle

    private var saveEditedSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionLabel("Salvar", systemImage: "square.and.arrow.down")
            Text("A legenda corrigida entra no MKV no lugar da faixa original, com o mesmo idioma, nome e flags. As outras faixas não mudam e o vídeo não é recodificado. Você escolhe entre um novo arquivo e o próprio arquivo.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button { workspace.requestSaveEdited() } label: {
                Label("Salvar no MKV…", systemImage: "square.and.arrow.down.on.square").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(!workspace.editor.hasDocument || workspace.isBusy)
            .hint("Salvar no MKV", "Grava a legenda corrigida no arquivo de vídeo, no lugar da antiga, e confere o resultado.")
            Button("Salvar como arquivo de legenda…", systemImage: "square.and.arrow.up") { workspace.exportSource() }
                .buttonStyle(.link)
                .disabled(!workspace.editor.hasDocument)
                .hint("Salvar como arquivo", "Salva a legenda corrigida como um arquivo ASS/SRT separado, sem mexer no vídeo.")
            Text("As correções ficam guardadas no projeto enquanto você edita; nada vai para o vídeo até você salvar.")
                .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            if let mux = workspace.lastMux {
                VerificationList(report: mux.report)
                Button("Mostrar no Finder", systemImage: "folder") { workspace.revealOutput() }.buttonStyle(.link)
            }
        }
    }

    // MARK: Translation

    private var translationSection: some View {
        @Bindable var app = app
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionLabel("Tradução para \(targetName)", systemImage: "translate")
            let editor = workspace.editor
            if editor.hasDocument {
                HStack {
                    Text("\(editor.translatedCount) de \(editor.translatableCount) falas")
                        .font(.callout.monospacedDigit())
                    Spacer()
                    if editor.translatableCount > 0 {
                        Gauge(value: Double(editor.translatedCount), in: 0...Double(max(1, editor.translatableCount))) {}
                            .gaugeStyle(.accessoryLinearCapacity)
                            .frame(width: 90)
                            .tint(Theme.translated)
                    }
                }
            }
            Menu {
                ForEach(workspace.linkableTracks) { track in
                    Button("Faixa \(track.displayLanguage.uppercased()) · \(track.name ?? track.codec)") { workspace.linkTranslation(track: track, undoManager: undoManager) }
                }
                Button("Arquivo de legenda…") { workspace.linkTranslationFile(undoManager: undoManager) }
                Divider()
                Button("Começar uma tradução vazia, à mão") { workspace.editor.startManualTranslation() }
                    .disabled(editor.translation != nil)
            } label: {
                Label("Usar uma tradução que já existe", systemImage: "link")
            }
            .menuStyle(.button)
            .buttonStyle(.link)
            .fixedSize()
            .disabled(workspace.isBusy || !editor.hasDocument)
            .hint("Usar uma tradução que já existe", "Carrega para revisar uma faixa já traduzida do arquivo ou um arquivo de legenda: as falas são casadas pelo tempo. Ou comece vazia para traduzir à mão.")
            Picker("Motor", selection: $app.settings.engine) {
                ForEach(EngineChoice.allCases) { Text($0.label).tag($0) }
            }
            .hint("Motor de tradução", "Quem traduz: a tradução da Apple (rápida, sem contexto), a Apple Intelligence (usa contexto e glossário) ou um servidor como Ollama ou LM Studio.")
            Text(app.settings.engine.summary).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Série / glossário", selection: Binding(get: { workspace.project.seriesID }, set: { workspace.assignSeries($0) })) {
                Text("Nenhuma").tag(UUID?.none)
                ForEach(app.series) { Text($0.name).tag(Optional($0.id)) }
            }
            .hint("Série / glossário", "Liga o episódio a uma série: o glossário, as notas e o elenco de vozes dela são usados na tradução e na dublagem.")
            Button("Editar séries e glossários…", systemImage: "books.vertical") { workspace.showSeries = true }
                .buttonStyle(.link)
                .hint("Editar séries e glossários", "Termos que devem ser traduzidos sempre do mesmo jeito (nomes, golpes, lugares) e notas de estilo da série.")
            Button(action: requestTranslate) {
                Label("Traduzir episódio inteiro", systemImage: "sparkles").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(!workspace.editor.hasDocument || workspace.isBusy)
            .hint("Traduzir episódio inteiro", "Traduz todas as falas mantendo estilos, tempos e tags. Se já houver tradução, você escolhe entre completar o que falta ou refazer tudo.")
            if let report = workspace.lastReport { ReportSummary(report: report) }
        }
    }

    private var targetName: String {
        Locale.current.localizedString(forIdentifier: app.settings.targetLanguage) ?? app.settings.targetLanguage
    }

    // MARK: Mux

    private var muxSection: some View {
        @Bindable var app = app
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionLabel("Gravar no MKV", systemImage: "film.stack")
            Text("A tradução vira uma faixa nova; a legenda original continua no arquivo.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Nome da faixa", text: $app.settings.trackName)
                .hint("Nome da faixa", "Nome que os players mostram no menu de legendas, por exemplo “Português (Brasil)”.")
            Toggle("Definir como legenda padrão", isOn: $app.settings.makeDefault)
                .hint("Legenda padrão", "Os players abrem o arquivo já com esta legenda ligada.")
            Toggle("Colocar antes das outras legendas", isOn: $app.settings.placeNewTrackFirst)
                .hint("Colocar primeiro", "A nova faixa aparece no topo da lista de legendas do player.")
            Button {
                workspace.requestEmbed()
            } label: {
                Label("Incorporar ao MKV…", systemImage: "square.and.arrow.down.on.square").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .disabled(workspace.editor.translation == nil || workspace.isBusy)
            .hint("Incorporar ao MKV", "Grava a tradução como nova faixa e confere o resultado. Antes você escolhe entre um novo arquivo e o próprio arquivo. O vídeo não é recodificado.")
            if let mux = workspace.lastMux {
                VerificationList(report: mux.report)
                Button("Mostrar no Finder", systemImage: "folder") { workspace.revealOutput() }
                    .buttonStyle(.link)
                    .hint("Mostrar no Finder", "Abre a pasta do novo arquivo com ele selecionado.")
            }
        }
    }
}

/// A radio-style row: one of several choices, with a short description.
struct ChoiceRow: View {
    let title: String
    let detail: String
    let selected: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ReportSummary: View {
    let report: TranslationReport

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label("\(report.translatedLines) traduzidas\(report.resumedLines > 0 ? " (\(report.resumedLines) retomadas)" : "")", systemImage: "checkmark.circle")
            let skipped = report.skipped.values.reduce(0, +)
            if skipped > 0 { Label("\(skipped) preservadas sem tradução (comentários, karaokê, desenhos)", systemImage: "lock") }
            if !report.segmentFallbackLines.isEmpty { Label("\(report.segmentFallbackLines.count) traduzidas por partes para manter as tags", systemImage: "puzzlepiece") }
            if !report.glossaryViolations.isEmpty { Label("\(report.glossaryViolations.count) avisos de glossário", systemImage: "book.closed").foregroundStyle(Theme.warning) }
            if !report.failedLines.isEmpty { Label("\(report.failedLines.count) falas sem tradução", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning) }
            if !report.structureProblems.isEmpty { Label("Estrutura: \(report.structureProblems.first ?? "")", systemImage: "xmark.octagon").foregroundStyle(Theme.failure) }
            Text("\(report.engineName) · \(report.finishedAt.timeIntervalSince(report.startedAt).formatted(.number.precision(.fractionLength(0)))) s")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, Theme.Spacing.xs)
    }
}

struct VerificationList: View {
    let report: VerificationReport

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(report.checks) { check in
                Label {
                    Text("\(Text(check.title).font(.caption.weight(.medium))) \(Text("— \(check.detail)").font(.caption).foregroundStyle(.secondary))")
                } icon: {
                    Image(systemName: check.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(check.passed ? Theme.translated : Theme.failure)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
