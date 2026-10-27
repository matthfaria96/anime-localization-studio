import AVFoundation
import DubbingKit
import Foundation
import MediaKit
import StudioCore

extension WorkspaceModel {
    // MARK: Automatic dub with the original voices

    var voiceModelsInstalled: Bool { ClonedVoiceSynthesizer(modelsDirectory: app.paths.voiceModels).modelsInstalled }

    /// Lines already synthesized for this episode (reused by the next dub).
    var cachedDubLines: Int {
        let clips = dubDirectory.appendingPathComponent("clips", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: clips.path)) ?? []).filter { $0.hasSuffix(".wav") && !$0.contains(".fit.") }.count
    }


    var dubDirectory: URL { StorageInventory(paths: app.paths).dubDirectory(projectID: project.id) }

    /// The audio track the dub is based on: the voices are cloned from it and its music and
    /// effects stay under the new voices.
    var dubAudioTrack: MediaTrack? {
        audioTracks.first { $0.id == project.dubAudioTrackID } ?? audioTracks.first(where: \.isDefault) ?? audioTracks.first
    }

    func selectDubAudio(_ id: Int) {
        guard id != dubAudioTrack?.id, !isBusy else { return }
        project.dubAudioTrackID = id
        try? store.save(project)
        // Voices and background came from the other track: they no longer apply.
        clearDubFiles()
        notice = (.info, "A dublagem agora usa o áudio “\(dubAudioTrack.map(Self.describe) ?? "")”. As vozes e o fundo serão tirados dele.")
    }

    /// Deletes the synthesized lines, voices and separated audio of this episode.
    /// Deletes the synthesized lines, voices and separated audio of this episode, and forgets
    /// the voices made from them, so the next dub starts from scratch.
    func clearDubFiles() {
        try? FileManager.default.removeItem(at: dubDirectory)
        voiceSamples = [:]
        lastDub = nil
        updateCast(Self.withoutVoices(cast))
        refreshDubStorage()
    }

    func updateCast(_ new: VoiceCast) { cast = new }

    /// The lines that will be spoken (from the translation, or the original if there is none).
    var dubSegments: [DubSegment] {
        guard let document = editor.translation ?? editor.source else { return [] }
        return DubbingPlan.segments(from: document)
    }

    func refreshDubStorage() { dubStorageBytes = StorageInventory.size(of: dubDirectory) }

    /// The same characters with no voice chosen, so every voice is made again.
    static func withoutVoices(_ cast: VoiceCast) -> VoiceCast {
        var cast = cast
        for i in cast.members.indices {
            cast.members[i].voiceID = nil
            cast.members[i].engine = nil
        }
        return cast
    }

    static func describe(_ track: MediaTrack) -> String {
        [Languages.display(track.displayLanguage), track.name, track.codec].compactMap { $0 }.joined(separator: " · ")
    }

    func prepareVoiceSamples() async {
        guard voiceSamples.isEmpty, claim("Amostras das vozes originais") else { return }
        operation = RunningOperation(kind: .extracting, fraction: 0, message: "Separando as vozes originais…")
        defer { release(); operation = nil }
        do {
            let samples = try await workflow().voiceSamples(project, audioTrackID: dubAudioTrack?.id) { step in
                Task { @MainActor in self.operation?.fraction = step.fraction; self.operation?.message = step.message }
            }
            voiceSamples = Dictionary(samples.map { ($0.speaker, $0.url) }, uniquingKeysWith: { a, _ in a })
        } catch {
            notice = (.error, LogRedactor.redact(error.localizedDescription))
        }
    }

    /// The guided dub window: confirm → running (with steps) → done or failed.
    struct DubSession {
        enum Phase {
            case confirm
            case running
            case done(url: URL, report: DubbingReport, verification: VerificationReport, replaced: Bool)
            case failed(String)
        }
        var phase: Phase = .confirm
        var replaceOriginal = false
        /// Throw away what earlier dubs generated (lines, voices, background) and start over.
        var regenerate = false
    }

    enum DubStage: Int, CaseIterable {
        case speakers, voices, speech, mix, file

        var title: String {
            switch self {
            case .speakers: "Identificar quem fala"
            case .voices: "Preparar a voz de cada personagem"
            case .speech: "Gerar as falas em português"
            case .mix: "Mixar com a música e os efeitos"
            case .file: "Gravar e verificar o MKV"
            }
        }

        /// Where each stage sits in the overall progress of `autoDub`.
        static func at(_ fraction: Double) -> DubStage {
            switch fraction {
            case ..<0.2: .speakers
            case ..<0.4: .voices
            case ..<0.85: .speech
            case ..<0.94: .mix
            default: .file
            }
        }
    }


    func startDubSession() {
        guard !isBusy, editor.translation != nil else { return }
        dubSession = DubSession()
    }

    /// Identifies who speaks (when the subtitle does not say), gives each character a voice (a
    /// clone of the original, or a similar macOS voice), dubs every line and writes the MKV.
    func autoDub(cast: VoiceCast, allowDiarizationDownload: Bool = false, undoManager: UndoManager?) {
        guard !isBusy, editor.translation != nil, claim("Dublagem automática") else { return }
        let replaceOriginal = dubSession?.replaceOriginal ?? false
        let regenerate = dubSession?.regenerate == true
        if regenerate {
            clearDubFiles()
            dubSession?.regenerate = false
        }
        let cast = regenerate ? Self.withoutVoices(cast) : cast
        let audioTrackID = dubAudioTrack?.id
        dubSession?.phase = .running
        editor.flush()
        notice = nil
        operation = RunningOperation(kind: .muxing, fraction: 0, message: "Preparando a dublagem…")
        let workflow = workflow()
        let systemVoices = Set(AVSpeechSynthesisVoice.speechVoices().map(\.name))
        let engine = app.settings.dubbingEngine.label, mode = app.settings.dubbingMode.label
        AppLog.shared.info("Dublagem iniciada: \(project.title) · \(engine) · \(mode) · \(replaceOriginal ? "no próprio arquivo" : "novo arquivo")")
        task = Task {
            do {
                var project = project
                if let document = editor.translation, DubbingPlan.segments(from: document).allSatisfy({ $0.speaker == "Desconhecido" }) {
                    let speakers = try await workflow.identifySpeakers(in: document, of: project, allowModelDownload: allowDiarizationDownload) { step in
                        Task { @MainActor in self.operation?.fraction = step.fraction * 0.2; self.operation?.message = step.message }
                    }
                    editor.setActors(speakers, undoManager: undoManager)
                    editor.flush()
                }
                let filled = try await workflow.automaticCast(project, cast: cast, systemVoices: systemVoices, audioTrackID: audioTrackID) { step in
                    Task { @MainActor in self.operation?.fraction = 0.2 + step.fraction * 0.2; self.operation?.message = step.message }
                }
                updateCast(filled)
                if app.settings.dubbingEngine == .original {
                    operation?.message = voiceModelsInstalled ? "Carregando o modelo de voz…" : "Baixando os modelos de voz (\(ClonedVoiceSynthesizer.downloadSize))…"
                    try await ClonedVoiceSynthesizer(modelsDirectory: app.paths.voiceModels).prepare()
                }
                let synthesizer = app.settings.makeSynthesizer(paths: app.paths)
                let (updated, output, report, verification) = try await workflow.dub(project, synthesizer: synthesizer, cast: filled,
                                                                                    replaceOriginal: replaceOriginal, audioTrackID: audioTrackID) { step in
                    Task { @MainActor in self.operation?.fraction = 0.4 + step.fraction * 0.6; self.operation?.message = step.message }
                }
                project = updated
                self.project = updated
                lastDub = (output, report, verification)
                lastMux = (output, verification)
                dubSession?.phase = .done(url: output, report: report, verification: verification, replaced: replaceOriginal)
                recordDub(DubRecord(outputPath: output.path, replacedOriginal: replaceOriginal, engine: engine, mode: mode,
                                    baseAudio: dubAudioTrack.map(Self.describe) ?? "—", language: app.settings.targetLanguage,
                                    lines: report.synthesized + report.reusedClips, failedLines: report.failed.count, verified: verification.passed))
                AppLog.shared.info("Dublagem concluída: \(output.path)")
                release()
                operation = nil
                refreshDubStorage()
                if replaceOriginal { await reload() }
                return
            } catch SpeakerDiarization.DiarizationError.modelsNotInstalled {
                dubSession?.phase = .confirm
                pendingDiarizationDownload = { self.autoDub(cast: cast, allowDiarizationDownload: true, undoManager: undoManager) }
            } catch is CancellationError {
                dubSession?.phase = .failed("Dublagem cancelada. As falas já geradas ficam guardadas e serão reaproveitadas na próxima vez. Nenhum arquivo foi criado ou alterado.")
            } catch {
                let message = Self.explainDubError(error)
                AppLog.shared.error("Dublagem falhou: \(message)")
                dubSession?.phase = .failed(message)
            }
            release()
            operation = nil
            refreshDubStorage()
        }
    }

    // MARK: History

    var dubHistory: [DubRecord] { project.dubHistory ?? [] }

    private func recordDub(_ record: DubRecord) {
        project.dubHistory = [record] + dubHistory
        try? store.save(project)
    }

    /// A separate file the app created, still on disk, that is not the video open now.
    func canTrashOutput(of record: DubRecord) -> Bool {
        !record.replacedOriginal && FileManager.default.fileExists(atPath: record.outputPath)
            && record.outputURL.standardizedFileURL.path != url.standardizedFileURL.path
    }

    /// Removes a dub from the history and, when asked, moves its file to the Trash.
    func deleteDubRecord(_ record: DubRecord, trashFile: Bool, resetVoices: Bool) {
        do {
            if trashFile && canTrashOutput(of: record) { try FileOps.trash(record.outputURL) }
            project.dubHistory = dubHistory.filter { $0.id != record.id }
            try store.save(project)
            if lastDub?.url.path == record.outputPath { lastDub = nil }
            if resetVoices { clearDubFiles() }
            notice = (.success, [trashFile ? "Dublagem apagada; o arquivo foi para a Lixeira." : "Dublagem tirada do histórico; o arquivo continua no disco.",
                                 resetVoices ? "Vozes e arquivos guardados limpos: a próxima dublagem começa do zero." : nil]
                .compactMap { $0 }.joined(separator: " "))
        } catch {
            notice = (.error, "Não foi possível apagar: \(LogRedactor.redact(error.localizedDescription))")
        }
    }

    /// Turns technical failures into what happened and what to do.
    static func explainDubError(_ error: Error) -> String {
        if case VoiceStudioClient.ClientError.notRunning = error {
            return "O VoiceStudio não está aberto, então as vozes originais não puderam ser clonadas. Abra o VoiceStudio e tente de novo, ou escolha “Vozes do macOS”. Nenhum arquivo foi criado ou alterado."
        }
        if case SynthesisError.engineUnavailable = error {
            return "O motor de voz parou de responder no meio da dublagem. Nenhum arquivo foi criado ou alterado; as falas já geradas serão reaproveitadas."
        }
        return LogRedactor.redact(error.localizedDescription) + " Nenhum arquivo foi criado ou alterado."
    }

    // MARK: Dub


    /// The cast of the series (shared by its episodes) or, without a series, of this project.
    func loadCast() -> VoiceCast {
        if let id = project.seriesID, let series = app.series.first(where: { $0.id == id }) { return series.cast ?? VoiceCast() }
        return project.cast ?? VoiceCast()
    }

    func saveCast(_ cast: VoiceCast) {
        if let id = project.seriesID, var series = app.series.first(where: { $0.id == id }) {
            series.cast = cast
            app.saveSeries(series)
        } else {
            project.cast = cast
            try? store.save(project)
        }
    }
}
