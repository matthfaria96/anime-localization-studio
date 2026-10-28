import MediaKit
import StudioCore
import SwiftUI
import TranslationKit

/// Right column of Legendar while translating: the translation tools, how the new track is
/// named and placed, and other ways to save. (Correcting shows nothing beside the editor.)
/// Writing into the video is always the “Gravar no vídeo…” button at the top.
struct InspectorView: View {
    @Bindable var workspace: WorkspaceModel
    let requestTranslate: () -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager

    private var editor: EditorModel { workspace.editor }

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
                translationSection
                trackSection
                otherWays
                if let mux = workspace.lastMux {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        SectionLabel("Última gravação", systemImage: "checkmark.seal")
                        Text(mux.url.lastPathComponent).font(.callout).lineLimit(2).textSelection(.enabled)
                        VerificationList(report: mux.report)
                        Button("Mostrar no Finder", systemImage: "folder") { workspace.revealOutput() }.buttonStyle(.link)
                    }
                }
            }
            .padding(Theme.Spacing.l)
            .animation(.smooth(duration: 0.25), value: workspace.operation)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: New subtitle

    private var translationSection: some View {
        @Bindable var app = app
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionLabel("Tradução", systemImage: "translate")
            if editor.hasDocument {
                HStack {
                    Text("\(editor.translatedCount) de \(Plural.count(editor.translatableCount, "fala", "falas"))").font(.callout.monospacedDigit())
                    Spacer()
                    if editor.translatableCount > 0 {
                        Gauge(value: Double(editor.translatedCount), in: 0...Double(max(1, editor.translatableCount))) {}
                            .gaugeStyle(.accessoryLinearCapacity)
                            .frame(width: 90)
                            .tint(Theme.translated)
                    }
                }
            }
            Picker("Motor", selection: $app.settings.engine) {
                ForEach(EngineChoice.allCases) { Text($0.label).tag($0) }
            }
            .hintVerbatim("Motor de tradução", app.settings.engine.summary)
            Picker("Glossário", selection: Binding(get: { workspace.project.seriesID }, set: { workspace.assignSeries($0) })) {
                Text("Nenhum").tag(UUID?.none)
                ForEach(app.series) { Text($0.name).tag(Optional($0.id)) }
            }
            .hint("Glossário da série", "Nomes, golpes e lugares que devem sair sempre iguais. O elenco de vozes da série também é usado na dublagem.")
            Button(action: requestTranslate) {
                Label(editor.translatedCount > 0 ? "Traduzir o que falta" : "Traduzir tudo", systemImage: "sparkles").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .disabled(!editor.hasDocument || workspace.isBusy)
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .hint("Traduzir (⇧⌘T)", "Traduz as falas mantendo estilos, tempos e tags. Se já houver tradução, você escolhe entre completar o que falta ou refazer tudo.")
            if let report = workspace.lastReport { ReportSummary(report: report) }
            Menu {
                ForEach(workspace.linkableTracks) { track in
                    Button("\(track.name ?? track.codec) · \(Languages.display(track.displayLanguage))") { workspace.linkTranslation(track: track, undoManager: undoManager) }
                }
                Button("Arquivo de legenda…") { workspace.linkTranslationFile(undoManager: undoManager) }
            } label: {
                Label("Trazer uma tradução pronta", systemImage: "link")
            }
            .menuStyle(.button)
            .buttonStyle(.link)
            .fixedSize()
            .disabled(workspace.isBusy || !editor.hasDocument)
            .hint("Trazer uma tradução pronta", "Usa como ponto de partida uma faixa do vídeo ou um arquivo já traduzido; as falas são casadas pelo tempo. ⌘Z desfaz.")
        }
    }

    private var trackSection: some View {
        @Bindable var app = app
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionLabel("Faixa no vídeo", systemImage: "film.stack")
            TextField("Nome", text: $app.settings.trackName)
                .hint("Nome da faixa", "O nome que os players mostram no menu de legendas. Acompanha o idioma, a menos que você escreva outro.")
            Toggle("Ligada ao abrir o vídeo", isOn: $app.settings.makeDefault)
                .hint("Legenda padrão", "Os players abrem o vídeo com esta legenda ligada.")
            Toggle("Primeira da lista", isOn: $app.settings.placeNewTrackFirst)
                .hint("Primeira da lista", "A faixa nova aparece no topo do menu de legendas do player.")
        }
    }

    // MARK: Other ways to save

    private var otherWays: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Button("Salvar como arquivo de legenda…", systemImage: "square.and.arrow.up") { workspace.exportTranslation() }
                .buttonStyle(.link)
                .disabled(editor.translation == nil)
                .hint("Salvar como arquivo", "Salva a tradução como um arquivo ASS/SRT separado, sem mexer no vídeo.")
            Button("Editar glossários…", systemImage: "books.vertical") { workspace.showSeries = true }.buttonStyle(.link)
                .hint("Editar glossários", "Termos que devem ser traduzidos sempre do mesmo jeito e notas de estilo da série.")
        }
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
