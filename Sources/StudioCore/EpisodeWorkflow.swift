import DubbingKit
import Foundation
import MediaKit
import SubtitleKit
import TranslationKit

public enum WorkflowError: Error, LocalizedError {
    case noTextSubtitle
    case bitmapOnly
    case notTranslated
    case noAudio
    case noBitmapSubtitle

    public var errorDescription: String? {
        switch self {
        case .noTextSubtitle: "O arquivo não tem legenda de texto (ASS, SSA ou SRT) para traduzir. Abra uma legenda externa no editor."
        case .bitmapOnly: "As legendas deste arquivo são imagens. Use “Reconhecer texto (OCR)” para legendas PGS; VobSub ainda não é suportado."
        case .notTranslated: "Traduza o episódio antes de dublar: a dublagem usa as falas da tradução e os tempos da legenda."
        case .noAudio: "O arquivo não tem faixa de áudio para servir de base à dublagem."
        case .noBitmapSubtitle: "O arquivo não tem legenda PGS. Legendas VobSub (DVD) ainda não são reconhecidas."
        }
    }
}

public struct WorkflowStep: Sendable, Hashable {
    public var fraction: Double
    public var message: String
}

/// The one-click path: pick the source subtitle, extract it, translate it with the series
/// glossary, save the translation in the project and, optionally, add it to a new MKV.
public struct EpisodeWorkflow: Sendable {
    public let paths: AppPaths
    public let settings: AppSettings
    public let engine: any TranslationEngine
    public let glossary: Glossary

    public init(paths: AppPaths, settings: AppSettings, engine: any TranslationEngine, glossary: Glossary) {
        self.paths = paths
        self.settings = settings
        self.engine = engine
        self.glossary = glossary
    }

    private var tools: ToolLocator { settings.toolLocator }
    private var store: ProjectStore { ProjectStore(paths: paths) }

    /// Makes sure the project has a source subtitle file and returns it with the media info.
    public func prepareSource(_ project: StudioProject) async throws -> (StudioProject, MediaInfo, URL) {
        var project = project
        let info = try await MediaInspector(tools: tools).inspect(project.mediaURL)
        if let external = project.externalSubtitlePath {
            return (project, info, URL(fileURLWithPath: external))
        }
        let chosen = project.sourceTrackID.flatMap { id in info.tracks.first { $0.id == id } }
            ?? info.bestSourceSubtitle(preferredLanguages: preferredSourceLanguages)
        guard let track = chosen, let ext = track.textSubtitleExtension, let format = SubtitleFormat(fileExtension: ext) else {
            throw info.tracks(.subtitles).contains(where: \.isBitmapSubtitle) ? WorkflowError.bitmapOnly : WorkflowError.noTextSubtitle
        }
        let fingerprint = Self.fingerprint(of: project.mediaURL)
        let mediaReplaced = project.mediaFingerprint != nil && project.mediaFingerprint != fingerprint
        let changedTrack = project.sourceTrackID != track.id || project.sourceFormat != format || mediaReplaced
        project.mediaFingerprint = fingerprint
        project.sourceTrackID = track.id
        project.sourceFormat = format
        let url = store.sourceSubtitleURL(for: project)!
        if changedTrack || !FileManager.default.fileExists(atPath: url.path) {
            // A new release at the same path may have new timing: keep a copy of the old work.
            if mediaReplaced { try? store.backupTranslation(of: project, language: settings.targetLanguage) }
            _ = try await TrackExtractor(tools: tools).extractSubtitle(track, from: info, to: url)
            if project.translationStatus == .new { project.translationStatus = .extracted }
            try store.save(project)
        }
        return (project, info, url)
    }

    /// Translates the lines that are still in the original language. Lines already translated
    /// or edited by hand are kept unless `retranslateAll` is set (the old file is backed up first).
    public func translate(_ project: StudioProject, retranslateAll: Bool = false,
                          progress: @escaping @Sendable (WorkflowStep) -> Void) async throws -> (StudioProject, TranslationReport) {
        progress(WorkflowStep(fraction: 0.02, message: "Analisando faixas…"))
        var (project, _, sourceURL) = try await prepareSource(project)
        let source = try SubtitleDocument.load(sourceURL)
        if project.sourceFormat == nil { project.sourceFormat = source.format }
        project.translationStatus = .translating
        try store.save(project)
        let checkpoint = store.checkpointURL(for: project, language: settings.targetLanguage)
        if retranslateAll { try? FileManager.default.removeItem(at: checkpoint) }
        let pipeline = TranslationPipeline(engine: engine, glossary: glossary, options: settings.translationOptions, checkpointURL: checkpoint,
                                           carriedContext: previousEpisodeContext(for: project))
        let existingURL = store.translationURL(for: project, language: settings.targetLanguage)
        let existing = retranslateAll ? nil : existingURL.flatMap { try? SubtitleDocument.load($0) }
        do {
            let (translated, report) = try await pipeline.run(source, existing: existing) { p in
                progress(WorkflowStep(fraction: 0.05 + p.fraction * 0.9, message: p.message))
            }
            let output = store.translationURL(for: project, language: settings.targetLanguage)!
            try store.backupTranslation(of: project, language: settings.targetLanguage)
            try translated.write(to: output)
            project.translationStatus = report.isComplete ? .translated : .failed
            project.lastReport = report
            try store.save(project)
            progress(WorkflowStep(fraction: 1, message: "Tradução concluída"))
            return (project, report)
        } catch {
            project.translationStatus = .failed
            try? store.save(project)
            throw error
        }
    }

    public func mux(_ project: StudioProject, progress: @escaping @Sendable (WorkflowStep) -> Void) async throws -> (StudioProject, URL, VerificationReport) {
        var project = project
        guard let translation = store.translationURL(for: project, language: settings.targetLanguage),
              FileManager.default.fileExists(atPath: translation.path) else { throw WorkflowError.noTextSubtitle }
        progress(WorkflowStep(fraction: 0.02, message: "Preparando incorporação…"))
        let info = try await MediaInspector(tools: tools).inspect(project.mediaURL)
        let track = NewTrack(file: translation, kind: .subtitles, language: settings.targetLanguage, name: settings.trackName,
                             isDefault: settings.makeDefault)
        let plan = MuxPlan(source: info, output: MuxPlan.defaultOutputURL(for: project.mediaURL, suffix: settings.targetLanguage.uppercased()),
                           newTracks: [track], clearOtherDefaults: settings.makeDefault, placeNewTracksFirst: settings.placeNewTrackFirst)
        let (url, report) = try await MKVMuxer(tools: tools).mux(plan) { value in
            progress(WorkflowStep(fraction: value, message: value < 0.9 ? "Gravando novo MKV…" : "Verificando integridade…"))
        }
        project.translationStatus = .muxed
        project.lastOutputPath = url.path
        project.lastVerification = report
        try store.save(project)
        return (project, url, report)
    }

    /// For videos without a text subtitle: transcribes the default audio track on the Mac and
    /// makes the result the project's source subtitle (SRT), ready to translate.
    public func transcribe(_ project: StudioProject, language: String, allowModelDownload: Bool,
                           identifySpeakers: Bool = false, allowDiarizationDownload: Bool = false,
                           progress: @escaping @Sendable (WorkflowStep) -> Void) async throws -> StudioProject {
        var project = project
        progress(WorkflowStep(fraction: 0.01, message: "Analisando faixas…"))
        let info = try await MediaInspector(tools: tools).inspect(project.mediaURL)
        guard let audio = info.tracks(.audio).first(where: \.isDefault) ?? info.tracks(.audio).first else { throw WorkflowError.noAudio }
        let directory = store.directory(for: project.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let wav = directory.appendingPathComponent(".transcription-\(UUID().uuidString.prefix(6)).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        _ = try await TrackExtractor(tools: tools).extractAudioWAV(audio, from: info, to: wav, sampleRate: 16_000, mono: true) { value in
            progress(WorkflowStep(fraction: value * 0.15, message: "Extraindo o áudio…"))
        }
        let diarizer = SpeakerDiarization(modelsDirectory: paths.diarizationModels)
        if identifySpeakers, !diarizer.modelsInstalled, !allowDiarizationDownload { throw SpeakerDiarization.DiarizationError.modelsNotInstalled }
        let share = identifySpeakers ? 0.6 : 0.85
        let lines = try await SpeechTranscription().transcribe(wav, language: language, allowModelDownload: allowModelDownload) { value in
            progress(WorkflowStep(fraction: 0.15 + value * share, message: "Transcrevendo a fala…"))
        }
        let document: SubtitleDocument
        if identifySpeakers {
            let turns = try await diarizer.diarize(wav, allowModelDownload: allowDiarizationDownload) { value in
                progress(WorkflowStep(fraction: 0.75 + value * 0.25, message: "Identificando quem fala…"))
            }
            document = SpeechTranscription.document(from: lines, speakers: SpeakerDiarization.assign(turns, to: lines.map { ($0.start, $0.end) }))
        } else {
            document = SpeechTranscription.document(from: lines)
        }
        let url = directory.appendingPathComponent("source.\(document.format.fileExtension)")
        try document.write(to: url)
        project.externalSubtitlePath = url.path
        project.sourceFormat = document.format
        project.sourceTrackID = nil
        project.translationStatus = .extracted
        try store.save(project)
        return project
    }

    /// Speaker of each spoken line of an existing subtitle, from the episode's default audio
    /// track. Comments, signs, drawings and karaoke are left alone.
    public func identifySpeakers(in document: SubtitleDocument, of project: StudioProject, allowModelDownload: Bool,
                                 progress: @escaping @Sendable (WorkflowStep) -> Void) async throws -> [Int: String] {
        let diarizer = SpeakerDiarization(modelsDirectory: paths.diarizationModels)
        guard diarizer.modelsInstalled || allowModelDownload else { throw SpeakerDiarization.DiarizationError.modelsNotInstalled }
        let info = try await MediaInspector(tools: tools).inspect(project.mediaURL)
        guard let audio = info.tracks(.audio).first(where: \.isDefault) ?? info.tracks(.audio).first else { throw WorkflowError.noAudio }
        let directory = store.directory(for: project.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let wav = directory.appendingPathComponent(".diarization-\(UUID().uuidString.prefix(6)).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        _ = try await TrackExtractor(tools: tools).extractAudioWAV(audio, from: info, to: wav, sampleRate: 16_000, mono: true) { value in
            progress(WorkflowStep(fraction: value * 0.2, message: "Extraindo o áudio…"))
        }
        let turns = try await diarizer.diarize(wav, allowModelDownload: allowModelDownload) { value in
            progress(WorkflowStep(fraction: 0.2 + value * 0.8, message: "Identificando quem fala…"))
        }
        let spoken = DubbingPlan.segments(from: document)
        let speakers = SpeakerDiarization.assign(turns, to: spoken.map { ($0.start, $0.end) })
        var result: [Int: String] = [:]
        for (segment, speaker) in zip(spoken, speakers) { if let speaker { result[segment.id] = speaker } }
        return result
    }

    /// For Blu-ray image subtitles (PGS): extracts the track, reads every caption with on-device
    /// text recognition and makes the result the project's source subtitle (SRT).
    public func recognizeBitmapSubtitle(_ project: StudioProject, language: String,
                                        progress: @escaping @Sendable (WorkflowStep) -> Void) async throws -> (StudioProject, skipped: Int) {
        var project = project
        progress(WorkflowStep(fraction: 0.01, message: "Analisando faixas…"))
        let info = try await MediaInspector(tools: tools).inspect(project.mediaURL)
        let pgs = info.tracks(.subtitles).filter { ["S_HDMV/PGS", "HDMV_PGS_SUBTITLE"].contains($0.codecID.uppercased()) }
        let languageCodes = [language.lowercased(), IntegrityVerifier.iso6392(for: language), String(language.prefix(2)).lowercased()]
        guard let track = pgs.first(where: { languageCodes.contains($0.language.lowercased()) || languageCodes.contains(($0.languageIETF ?? "").lowercased()) })
                ?? pgs.first else { throw WorkflowError.noBitmapSubtitle }
        let directory = store.directory(for: project.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sup = directory.appendingPathComponent(".ocr-\(UUID().uuidString.prefix(6)).sup")
        defer { try? FileManager.default.removeItem(at: sup) }
        progress(WorkflowStep(fraction: 0.05, message: "Extraindo a legenda em imagem…"))
        _ = try await TrackExtractor(tools: tools).extractRaw(track, from: info, to: sup)
        let (document, skipped) = try await SubtitleOCR().document(fromPGS: try Data(contentsOf: sup), language: language) { value in
            progress(WorkflowStep(fraction: 0.1 + value * 0.9, message: "Reconhecendo o texto das legendas…"))
        }
        let url = directory.appendingPathComponent("source.srt")
        try document.write(to: url)
        project.externalSubtitlePath = url.path
        project.sourceFormat = .srt
        project.sourceTrackID = nil
        project.translationStatus = .extracted
        try store.save(project)
        return (project, skipped)
    }

    /// Voice-over dub: synthesizes the translated lines with the cast, mixes them over the
    /// original audio, and writes a new MKV with the dubbed audio and the translated subtitle
    /// added (all original tracks kept, video not re-encoded).
    public func dub(_ project: StudioProject, synthesizer: any SpeechSynthesizer, cast: VoiceCast,
                    progress: @escaping @Sendable (WorkflowStep) -> Void) async throws -> (StudioProject, URL, DubbingReport, VerificationReport) {
        var project = project
        guard let translationURL = store.translationURL(for: project, language: settings.targetLanguage),
              let translation = try? SubtitleDocument.load(translationURL) else { throw WorkflowError.notTranslated }
        progress(WorkflowStep(fraction: 0.01, message: "Analisando faixas…"))
        let info = try await MediaInspector(tools: tools).inspect(project.mediaURL)
        guard let audio = info.tracks(.audio).first(where: \.isDefault) ?? info.tracks(.audio).first else { throw WorkflowError.noAudio }
        let segments = DubbingPlan.segments(from: translation)
        let work = store.directory(for: project.id).appendingPathComponent("Dub", isDirectory: true)
        let dubAudio = store.directory(for: project.id).appendingPathComponent("dub.\(settings.targetLanguage).m4a")
        let pipeline = DubbingPipeline(synthesizer: synthesizer, tools: tools, workDirectory: work, cast: cast,
                                       options: DubbingOptions(maxSpeedup: settings.dubbingMaxSpeedup, defaultVoice: settings.dubbingDefaultVoice,
                                                               mode: settings.dubbingMode))
        let report = try await pipeline.run(segments, media: info, audioTrack: audio, output: dubAudio) { value, message in
            progress(WorkflowStep(fraction: value * 0.85, message: message))
        }
        let localized = Locale(identifier: "pt_BR").localizedString(forIdentifier: settings.targetLanguage) ?? settings.targetLanguage
        let languageName = localized.prefix(1).uppercased() + localized.dropFirst()
        let tracks = [
            NewTrack(file: dubAudio, kind: .audio, language: settings.targetLanguage, name: "\(languageName) · dublagem IA (\(settings.dubbingMode.trackSuffix))", isDefault: settings.makeDefault),
            NewTrack(file: translationURL, kind: .subtitles, language: settings.targetLanguage, name: settings.trackName, isDefault: settings.makeDefault)
        ]
        let plan = MuxPlan(source: info, output: MuxPlan.defaultOutputURL(for: project.mediaURL, suffix: "\(settings.targetLanguage.uppercased()) DUB"),
                           newTracks: tracks, clearOtherDefaults: settings.makeDefault, placeNewTracksFirst: settings.placeNewTrackFirst)
        let (url, verification) = try await MKVMuxer(tools: tools).mux(plan) { value in
            progress(WorkflowStep(fraction: 0.85 + value * 0.15, message: value < 0.9 ? "Gravando novo MKV…" : "Verificando integridade…"))
        }
        project.dubbingStatus = report.failed.isEmpty ? .muxed : .failed
        project.lastDubReport = report
        project.lastOutputPath = url.path
        project.lastVerification = verification
        try store.save(project)
        return (project, url, report, verification)
    }

    /// The last translated lines of the previous episode in the same folder (by name order),
    /// when that episode was translated in the app.
    func previousEpisodeContext(for project: StudioProject, lines: Int = 8) -> [TranslationContext.PreviousLine] {
        let folder = project.mediaURL.deletingLastPathComponent()
        let videos = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["mkv", "mp4", "m4v", "mov", "webm", "avi", "ts", "m2ts"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard let index = videos.firstIndex(where: { $0.standardizedFileURL == project.mediaURL.standardizedFileURL }), index > 0,
              let previous = store.existingProject(for: videos[index - 1]),
              let sourceURL = store.sourceSubtitleURL(for: previous), let translationURL = store.translationURL(for: previous, language: settings.targetLanguage),
              let source = try? SubtitleDocument.load(sourceURL), let translation = try? SubtitleDocument.load(translationURL),
              source.count == translation.count else { return [] }
        let pairs = (0..<source.count).compactMap { i -> TranslationContext.PreviousLine? in
            guard source.skipReason(at: i) == nil, source.rawText(at: i) != translation.rawText(at: i) else { return nil }
            let actor = source.cues[i].actor
            return TranslationContext.PreviousLine(speaker: actor.isEmpty ? nil : actor, source: source.plainText(at: i), translation: translation.plainText(at: i))
        }
        return Array(pairs.suffix(lines))
    }

    static func fingerprint(of url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        return "\(values.fileSize ?? 0)-\(Int(values.contentModificationDate?.timeIntervalSince1970 ?? 0))"
    }

    private var preferredSourceLanguages: [String] {
        var languages = ["eng", "en", "jpn", "ja"]
        if let source = settings.sourceLanguage {
            languages.insert(contentsOf: [source, IntegrityVerifier.iso6392(for: source)], at: 0)
        }
        return languages
    }
}
