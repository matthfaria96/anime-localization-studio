import DubbingKit
import MediaKit
import StudioCore
import SwiftUI

/// Dublar: what will be dubbed and one button, the dubs already made, and (collapsed) the
/// voices. Everything shown comes from the model, so clearing or deleting updates the page.
struct DubbingView: View {
    @Bindable var workspace: WorkspaceModel
    @Environment(AppModel.self) private var app
    @State private var studioConnected: Bool?
    @State private var studioVoices: [VoiceStudioClient.Voice] = []
    @State private var recordToDelete: DubRecord?
    @State private var confirmRestart = false
    @AppStorage("dubVoicesExpanded") private var voicesExpanded = false

    private var segments: [DubSegment] { workspace.dubSegments }
    private var isTranslated: Bool { workspace.editor.translation != nil }
    private var usesClones: Bool { app.settings.dubbingEngine == .voiceStudio }
    private var language: String { Languages.name(for: app.settings.targetLanguage) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                Text("Dublar").font(.largeTitle.weight(.semibold))
                if let operation = workspace.operation {
                    OperationProgress(message: operation.message, fraction: operation.fraction) { workspace.cancelOperation() }
                }
                if let notice = workspace.notice {
                    HStack {
                        InlineMessage(kind: notice.kind, text: notice.text)
                        if let action = workspace.noticeAction { Button(action.title, action: action.run).buttonStyle(.link) }
                    }
                }
                summary
                if let dub = workspace.lastDub { DubResultPanel(workspace: workspace, dub: dub) }
                history
                DisclosureGroup(isExpanded: $voicesExpanded) {
                    DubVoicesSection(workspace: workspace, studioConnected: studioConnected, studioVoices: studioVoices) { await checkStudio() }
                        .padding(.top, Theme.Spacing.m)
                } label: {
                    Label("Ajustar vozes e personagens", systemImage: "person.2.wave.2").font(.headline)
                        .hint("Ajustar vozes e personagens", "Motor de voz, modo de mixagem e a voz de cada personagem. O app escolhe tudo sozinho; abra só se quiser mudar.")
                }
                restart
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .paneBackground()
        .task {
            workspace.refreshDubStorage()
            rebuildCast()
            await checkStudio()
        }
        .onChange(of: workspace.editor.revision) { rebuildCast() }
        .modifier(SpeakerModelConsent(workspace: workspace))
        .confirmationDialog("Recomeçar a dublagem do zero?", isPresented: $confirmRestart) {
            Button("Recomeçar do zero", role: .destructive) { workspace.clearDubFiles() }
        } message: {
            Text("Apaga as falas geradas, as vozes de cada personagem e a música de fundo deste vídeo (\(bytes)). A próxima dublagem refaz tudo. Os vídeos já dublados e o histórico não são apagados.")
        }
        .confirmationDialog("Apagar esta dublagem?", isPresented: Binding(get: { recordToDelete != nil }, set: { if !$0 { recordToDelete = nil } }),
                            presenting: recordToDelete) { record in
            Button(workspace.canTrashOutput(of: record) ? "Apagar o vídeo dublado e recomeçar do zero" : "Tirar do histórico e recomeçar do zero",
                   role: .destructive) {
                workspace.deleteDubRecord(record, trashFile: true, resetVoices: true)
            }
            Button("Só tirar do histórico") { workspace.deleteDubRecord(record, trashFile: false, resetVoices: false) }
        } message: { record in
            Text(deleteMessage(record))
        }
        .sheet(isPresented: Binding(get: { workspace.dubSession != nil }, set: { if !$0 && !isDubRunning { workspace.dubSession = nil } })) {
            DubSessionSheet(workspace: workspace, cast: $workspace.cast, studioConnected: studioConnected, segmentCount: segments.count)
        }
    }

    private var isDubRunning: Bool { if case .running = workspace.dubSession?.phase { true } else { false } }
    private var bytes: String { ByteCountFormatter.string(fromByteCount: workspace.dubStorageBytes, countStyle: .file) }

    // MARK: What will be dubbed

    private var summary: some View {
        Panel {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Spacing.l, verticalSpacing: Theme.Spacing.m) {
                GridRow {
                    rowTitle("Voz e fundo", "waveform")
                    if workspace.audioTracks.count > 1 {
                        Picker("Voz e fundo", selection: Binding(get: { workspace.dubAudioTrack?.id ?? -1 }, set: { workspace.selectDubAudio($0) })) {
                            ForEach(workspace.audioTracks) { Text(WorkspaceModel.describe($0)).tag($0.id) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .disabled(workspace.isBusy)
                        .hint("Áudio de base", "A faixa de onde saem as vozes originais (para recriar cada personagem) e a música e os efeitos que ficam por baixo. Use o áudio no idioma original. Trocar recomeça as vozes do zero.")
                    } else {
                        Text(workspace.dubAudioTrack.map(WorkspaceModel.describe) ?? "O vídeo não tem áudio")
                            .hint("Áudio de base", "As vozes originais e a música e os efeitos saem desta faixa.")
                    }
                }
                GridRow {
                    rowTitle("Texto falado", "text.bubble")
                    if isTranslated {
                        Text("Legenda em \(language) · \(Plural.count(segments.count, "fala", "falas"))")
                            .hint("Texto falado", "O app fala o texto da legenda traduzida, no tempo de cada fala. O áudio não é interpretado: corrigir a tradução muda o que é dito.")
                    } else {
                        HStack {
                            Text("Ainda não há legenda traduzida.").foregroundStyle(.secondary)
                            Button("Criar em Legendar") { app.show(.subtitles) }.buttonStyle(.link)
                                .hint("Criar em Legendar", "A dublagem fala uma legenda traduzida. Crie uma em Legendar › Uma legenda nova.")
                        }
                    }
                }
                GridRow {
                    rowTitle("Resultado", "square.and.arrow.down")
                    Text("Nova faixa de áudio em \(language)")
                        .hint("Resultado", "A faixa dublada entra no vídeo como padrão; o áudio original e as legendas continuam lá. Antes de gravar, o app pergunta: novo arquivo ou este arquivo.")
                }
                GridRow {
                    rowTitle("Vozes", "person.wave.2")
                    HStack {
                        Text(voicesSummary)
                            .hint("Vozes", app.settings.dubbingEngine == .original
                                  ? "Cada personagem fala com a própria voz, recriada do áudio original deste vídeo. Quem fala cada linha vem do campo Personagem da legenda (ou é identificado pelo áudio)."
                                  : "Vozes escolhidas pelo tom de cada personagem.")
                        Button(voicesExpanded ? "Fechar ajustes" : "Ajustar") { withAnimation { voicesExpanded.toggle() } }.buttonStyle(.link)
                    }
                }
            }
            Divider().padding(.vertical, Theme.Spacing.xs)
            HStack {
                if app.settings.dubbingEngine == .original && !ClonedVoiceSynthesizer.supports(app.settings.targetLanguage) {
                    Label("A voz original ainda não fala \(language). Use as vozes do macOS ou o VoiceStudio.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(Theme.warning)
                } else if usesClones && studioConnected == false {
                    Label("O VoiceStudio não está aberto.", systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Theme.warning)
                }
                Spacer()
                Button { workspace.startDubSession() } label: { Label("Dublar…", systemImage: "waveform") }
                    .buttonStyle(.glassProminent)
                    .tint(.accentColor)
                    .controlSize(.large)
                    .disabled(!isTranslated || segments.isEmpty || workspace.isBusy || unsupportedLanguage)
                    .hintVerbatim("Dublar…", isTranslated
                        ? "Mostra o resumo, pergunta onde gravar e então dubla o vídeo inteiro, mostrando cada etapa."
                        : "Primeiro crie a legenda traduzida em Legendar.")
            }
        }
    }

    private var unsupportedLanguage: Bool {
        app.settings.dubbingEngine == .original && !ClonedVoiceSynthesizer.supports(app.settings.targetLanguage)
    }

    private var voicesSummary: String {
        switch app.settings.dubbingEngine {
        case .original:
            "A própria voz de cada personagem\(app.settings.dubbingPerLineVoice ? ", com a emoção de cada fala" : "") · \(app.settings.dubbingMode.label)"
        default: "\(app.settings.dubbingEngine.label) · \(app.settings.dubbingMode.label)"
        }
    }

    private func rowTitle(_ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon).foregroundStyle(.secondary).frame(minWidth: 130, alignment: .leading)
    }

    // MARK: History

    private var history: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            SectionLabel("Dublagens feitas", systemImage: "clock.arrow.circlepath")
            if workspace.dubHistory.isEmpty {
                Text("Nenhuma ainda. Cada dublagem terminada aparece aqui.").font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(workspace.dubHistory.enumerated()), id: \.element.id) { index, record in
                        if index > 0 { Divider() }
                        historyRow(record)
                    }
                }
                .background(.background.secondary, in: .rect(cornerRadius: Theme.Radius.medium))
            }
        }
    }

    private func historyRow(_ record: DubRecord) -> some View {
        let exists = FileManager.default.fileExists(atPath: record.outputPath)
        let ok = record.verified && record.failedLines == 0
        return HStack(spacing: Theme.Spacing.m) {
            Image(systemName: ok ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Theme.translated : Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(record.outputURL.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if record.replacedOriginal { Tag(text: "Este arquivo") }
                    if !exists { Tag(text: "Não encontrado", tint: Theme.warning) }
                }
                Text("\(record.date.formatted(date: .abbreviated, time: .shortened)) · \(record.engine) · \(Plural.count(record.lines, "fala", "falas"))\(record.failedLines > 0 ? ", \(record.failedLines) sem voz" : "")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .hintVerbatim(record.outputURL.lastPathComponent, "\(record.mode) · áudio \(record.baseAudio) · \(Languages.name(for: record.language))\(ok ? " · verificada" : " · com avisos")\n\(record.outputPath)")
            Spacer(minLength: Theme.Spacing.s)
            if exists {
                Button("Mostrar no Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([record.outputURL]) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .hint("Mostrar no Finder", "Abre a pasta do vídeo dublado com ele selecionado.")
            }
            Button("Apagar…", systemImage: "trash") { recordToDelete = record }
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .disabled(workspace.isBusy)
                .hint("Apagar esta dublagem", "Pergunta antes: apagar e recomeçar as vozes do zero, ou só tirar do histórico.")
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.s)
    }

    private func deleteMessage(_ record: DubRecord) -> String {
        let reset = "Recomeçar do zero também apaga as vozes de cada personagem e os arquivos guardados desta dublagem (\(bytes)); a próxima dublagem refaz tudo."
        if workspace.canTrashOutput(of: record) { return "“\(record.outputURL.lastPathComponent)” vai para a Lixeira. \(reset)" }
        if record.replacedOriginal { return "Esta dublagem foi gravada neste arquivo, que não é apagado. \(reset)" }
        return "O arquivo não está mais no disco. \(reset)"
    }

    // MARK: Restart

    private var restart: some View {
        HStack {
            Text(workspace.dubStorageBytes > 0 ? "Arquivos guardados para a próxima dublagem: \(bytes)" : "Nenhum arquivo guardado.")
                .font(.caption).foregroundStyle(.secondary)
                .hint("Arquivos guardados", "Falas geradas, vozes separadas e música de fundo. Deixam a próxima dublagem mais rápida: só o que mudou é refeito.")
            Spacer()
            Button("Recomeçar do zero…", systemImage: "arrow.counterclockwise") { confirmRestart = true }
                .controlSize(.small)
                .disabled(workspace.isBusy || (workspace.dubStorageBytes == 0 && workspace.cast.members.allSatisfy { $0.voiceID == nil }))
                .hint("Recomeçar do zero", "Pergunta antes. Apaga as vozes escolhidas e os arquivos guardados, para a próxima dublagem refazer tudo.")
        }
    }

    // MARK: Actions

    private func checkStudio() async {
        studioConnected = nil
        let client = VoiceStudioClient(baseURL: app.settings.voiceStudioURL)
        do {
            _ = try await client.capabilities()
            studioVoices = try await client.voices()
            studioConnected = true
        } catch {
            studioConnected = false
        }
    }

    private func rebuildCast() {
        var cast = workspace.cast
        cast.addMissing(from: DubbingPlan.speakers(in: segments).filter { $0 != "Desconhecido" })
        workspace.updateCast(cast)
    }
}

/// Right after a dub: what came out and which lines need a look.
private struct DubResultPanel: View {
    @Bindable var workspace: WorkspaceModel
    let dub: (url: URL, report: DubbingReport, verification: VerificationReport)

    var body: some View {
        Panel {
            HStack {
                SectionLabel("Última dublagem", systemImage: "checkmark.seal")
                Spacer()
                Button("Mostrar no Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([dub.url]) }
                    .buttonStyle(.link)
            }
            let r = dub.report
            Text("\(Plural.count(r.synthesized + r.reusedClips, "fala dublada", "falas dubladas")) · \(r.spedUp.count) aceleradas · \(r.failed.count) sem voz")
                .font(.callout)
            let segments = workspace.dubSegments
            ForEach(r.problemLines.sorted().prefix(8), id: \.self) { id in
                Button("Fala \(id + 1): \(segments.first { $0.id == id }?.text ?? "")") {
                    workspace.select(id, seek: true)
                    workspace.app.show(.subtitles)
                }
                .buttonStyle(.link)
                .lineLimit(1)
                .hint("Revisar a fala", "Abre esta fala em Legendar. Corrigir o texto e dublar de novo refaz só as falas alteradas.")
            }
            if !dub.verification.passed { VerificationList(report: dub.verification) }
        }
    }
}
