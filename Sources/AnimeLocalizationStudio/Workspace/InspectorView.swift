import MediaKit
import StudioCore
import SwiftUI
import TranslationKit

/// Right column of the episode: tracks, translation and the new MKV.
struct InspectorView: View {
    @Bindable var workspace: WorkspaceModel
    let requestTranslate: () -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                if let operation = workspace.operation {
                    let cancel: (() -> Void)? = operation.kind == .loading ? nil : { workspace.cancelOperation() }
                    OperationProgress(message: operation.message, fraction: operation.fraction, onCancel: cancel)
                }
                if let notice = workspace.notice { InlineMessage(kind: notice.kind, text: notice.text) }
                tracksSection
                translationSection
                muxSection
            }
            .padding(Theme.Spacing.l)
            .animation(.smooth(duration: 0.25), value: workspace.operation)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: Tracks

    private var tracksSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionLabel("Faixas", systemImage: "list.bullet.rectangle")
            if let info = workspace.info {
                ForEach(info.tracks) { track in TrackRow(track: track, isSource: track.id == workspace.project.sourceTrackID && workspace.project.externalSubtitlePath == nil) }
                if !info.attachments.isEmpty || info.chapterCount > 0 {
                    HStack(spacing: Theme.Spacing.s) {
                        if !info.attachments.isEmpty { Label("\(info.attachments.filter(\.isFont).count) fontes anexadas", systemImage: "textformat") }
                        if info.chapterCount > 0 { Label("\(info.chapterCount) capítulos", systemImage: "bookmark") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                let textTracks = info.tracks(.subtitles).filter { $0.textSubtitleExtension != nil }
                if textTracks.count > 1 {
                    Picker("Legenda de origem", selection: Binding(get: { workspace.project.sourceTrackID ?? -1 }, set: { workspace.selectSourceTrack($0) })) {
                        ForEach(textTracks) { Text("\($0.id) · \($0.displayLanguage) · \($0.name ?? $0.codec)").tag($0.id) }
                    }
                    .disabled(workspace.isBusy)
                    .hint("Legenda de origem", "Qual faixa de legenda do arquivo é o original a traduzir.")
                }
                if workspace.project.externalSubtitlePath != nil {
                    Label("Usando legenda externa", systemImage: "doc.text").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Analisando…").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Translation

    private var translationSection: some View {
        @Bindable var app = app
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionLabel("Tradução", systemImage: "translate")
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

    // MARK: Mux

    private var muxSection: some View {
        @Bindable var app = app
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionLabel("Novo MKV", systemImage: "film.stack")
            TextField("Nome da faixa", text: $app.settings.trackName)
                .hint("Nome da faixa", "Nome que os players mostram no menu de legendas, por exemplo “Português (Brasil)”.")
            Toggle("Definir como legenda padrão", isOn: $app.settings.makeDefault)
                .hint("Legenda padrão", "Os players abrem o arquivo já com esta legenda ligada.")
            Toggle("Colocar antes das outras legendas", isOn: $app.settings.placeNewTrackFirst)
                .hint("Colocar primeiro", "A nova faixa aparece no topo da lista de legendas do player.")
            Text("O original não é alterado. O vídeo e os áudios são copiados sem recodificação, e o resultado é verificado antes de ser salvo.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button {
                workspace.embedTranslation()
            } label: {
                Label("Incorporar ao MKV", systemImage: "square.and.arrow.down.on.square").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .disabled(workspace.editor.translation == nil || workspace.isBusy)
            .hint("Incorporar ao MKV", "Cria um novo MKV com a legenda traduzida, verifica o resultado e mantém todas as faixas originais. O original não é alterado.")
            if let mux = workspace.lastMux {
                VerificationList(report: mux.report)
                Button("Mostrar no Finder", systemImage: "folder") { workspace.revealOutput() }
                    .buttonStyle(.link)
                    .hint("Mostrar no Finder", "Abre a pasta do novo arquivo com ele selecionado.")
            }
        }
    }
}

private struct TrackRow: View {
    let track: MediaTrack
    let isSource: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(isSource ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 1) {
                Text(track.name ?? track.kind.label).font(.callout).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Tag(text: track.displayLanguage.uppercased())
            if track.isDefault { Tag(text: "Padrão", tint: .accentColor) }
            if track.isForced { Tag(text: "Forçada", tint: Theme.warning) }
        }
        .accessibilityElement(children: .combine)
        .hintVerbatim(track.name ?? track.kind.label, isSource ? "Esta é a legenda usada como original para traduzir. Formato: \(track.codec)." : "\(track.kind.label) · \(track.codec) · idioma \(track.displayLanguage)\(track.isDefault ? " · faixa padrão" : "")")
    }

    private var icon: String {
        switch track.kind {
        case .video: "film"
        case .audio: "waveform"
        case .subtitles: isSource ? "captions.bubble.fill" : "captions.bubble"
        case .other: "doc"
        }
    }

    private var detail: String {
        switch track.kind {
        case .video: [track.codec, track.width.map { "\($0)×\(track.height ?? 0)" }].compactMap { $0 }.joined(separator: " · ")
        case .audio: [track.codec, track.channels.map { "\($0) canais" }].compactMap { $0 }.joined(separator: " · ")
        case .subtitles: track.isBitmapSubtitle ? "\(track.codec) · imagem (precisa de OCR)" : track.codec
        case .other: track.codec
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
