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

    /// - Parameter replaceOriginal: write the result over the original file (the original goes
    ///   to the Trash after the new file is verified) instead of creating “Nome [PT-BR].mkv”.
    public func mux(_ project: StudioProject, replaceOriginal: Bool = false,
                    progress: @escaping @Sendable (WorkflowStep) -> Void) async throws -> (StudioProject, URL, VerificationReport) {
        var project = project
        guard let translation = store.translationURL(for: project, language: settings.targetLanguage),
              FileManager.default.fileExists(atPath: translation.path) else { throw WorkflowError.noTextSubtitle }
        progress(WorkflowStep(fraction: 0.02, message: "Preparando incorporação…"))
        let info = try await MediaInspector(tools: tools).inspect(project.mediaURL)
        let track = NewTrack(file: translation, kind: .subtitles, language: settings.targetLanguage, name: settings.trackName,
                             isDefault: settings.makeDefault)
        var plan = MuxPlan(source: info, output: MuxPlan.defaultOutputURL(for: project.mediaURL, suffix: settings.targetLanguage.uppercased()),
                           newTracks: [track], clearOtherDefaults: settings.makeDefault, placeNewTracksFirst: settings.placeNewTrackFirst)
        plan.replaceSource = replaceOriginal
        let previousSource = project.sourceTrackID.flatMap { id in info.tracks.first { $0.id == id } }
        let (url, report) = try await MKVMuxer(tools: tools).mux(plan) { value in
            progress(WorkflowStep(fraction: value, message: value < 0.9 ? "Gravando novo MKV…" : "Verificando integridade…"))
        }
        project.translationStatus = .muxed
        project.lastOutputPath = url.path
        project.lastVerification = report
        if replaceOriginal {
            // Track ids can shift in the rewritten file; find the original subtitle again.
            if let previous = previousSource, let output = report.outputInfo {
                project.sourceTrackID = output.tracks(.subtitles).first { IntegrityVerifier.sameTrack(previous, $0) }?.id ?? project.sourceTrackID
            }
            project.mediaFingerprint = Self.fingerprint(of: url)
        }
        try store.save(project)
        return (project, url, report)
    }

    /// Uses an existing translation (another track of the file, or a subtitle file) as the
    /// project's translation, aligned by time to the original. The current one is backed up.
    public func linkTranslation(_ project: StudioProject, track: MediaTrack? = nil, file: URL? = nil) async throws -> (StudioProject, TranslationAlignment.Result) {
        var (project, info, sourceURL) = try await prepareSource(project)
        let source = try SubtitleDocument.load(sourceURL)
        let other: SubtitleDocument
        if let file {
            other = try SubtitleDocument.load(file)
        } else if let track, let ext = track.textSubtitleExtension {
            let temp = store.directory(for: project.id).appendingPathComponent(".link-\(UUID().uuidString.prefix(6)).\(ext)")
            defer { try? FileManager.default.removeItem(at: temp) }
            _ = try await TrackExtractor(tools: tools).extractSubtitle(track, from: info, to: temp)
            other = try SubtitleDocument.load(temp)
        } else {
            throw WorkflowError.noTextSubtitle
        }
        let result = TranslationAlignment.align(other, onto: source)
        try store.backupTranslation(of: project, language: settings.targetLanguage)
        try result.document.write(to: store.translationURL(for: project, language: settings.targetLanguage)!)
        project.translationStatus = .reviewed
        try store.save(project)
        return (project, result)
    }

    /// Another subtitle track shown beside the one being edited, matched by time. Nothing is saved.
    public func referenceLines(_ project: StudioProject, track: MediaTrack) async throws -> [Int: String] {
        let (project, info, sourceURL) = try await prepareSource(project)
        guard let ext = track.textSubtitleExtension else { throw WorkflowError.noTextSubtitle }
        let temp = store.directory(for: project.id).appendingPathComponent(".reference-\(UUID().uuidString.prefix(6)).\(ext)")
        defer { try? FileManager.default.removeItem(at: temp) }
        _ = try await TrackExtractor(tools: tools).extractSubtitle(track, from: info, to: temp)
        return TranslationAlignment.reference(try SubtitleDocument.load(temp), for: try SubtitleDocument.load(sourceURL))
    }

    /// A text track of the file in the target language that is not the original, to link
    /// automatically when the project has no translation yet (e.g. a file muxed earlier).
    public func existingTranslationTrack(in info: MediaInfo, project: StudioProject) -> MediaTrack? {
        let target = settings.targetLanguage.lowercased()
        let base = String(target.prefix(2))
        return info.tracks(.subtitles).first { track in
            track.id != project.sourceTrackID && track.textSubtitleExtension != nil
                && ((track.languageIETF ?? "").lowercased() == target || track.language.lowercased() == IntegrityVerifier.iso6392(for: target)
                    || (track.languageIETF ?? "").lowercased().hasPrefix(base))
        }
    }

    /// Sets the default audio and subtitle tracks in the file itself (instant) or in a copy.
    public func applyDefaultTracks(_ project: StudioProject, defaults: TrackFlagEditor.Defaults, inPlace: Bool) async throws -> (StudioProject, URL) {
        var project = project
        let info = try await MediaInspector(tools: tools).inspect(project.mediaURL)
        let copy = inPlace ? nil : project.mediaURL.deletingLastPathComponent()
            .appendingPathComponent("\(project.mediaURL.deletingPathExtension().lastPathComponent) [faixas]").appendingPathExtension("mkv")
        let url = try await TrackFlagEditor(tools: tools).apply(defaults, to: info, copyTo: copy)
        if inPlace {
            project.mediaFingerprint = Self.fingerprint(of: project.mediaURL)
            try store.save(project)
        }
        return (project, url)
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

    /// Clips of each speaker's original voice (isolated from music), cached in the project.
    public func voiceSamples(_ project: StudioProject, audioTrackID: Int? = nil, progress: @escaping @Sendable (WorkflowStep) -> Void) async throws -> [OriginalVoices.Sample] {
        let (_, info, sourceURL) = try await prepareSource(project)
        let source = try SubtitleDocument.load(sourceURL)
        let translation = store.translationURL(for: project, language: settings.targetLanguage).flatMap { try? SubtitleDocument.load($0) }
        guard let audio = audioTrackID.flatMap({ id in info.tracks.first { $0.id == id } }) ?? info.tracks(.audio).first(where: \.isDefault) ?? info.tracks(.audio).first
        else { throw WorkflowError.noAudio }
        let lines = DubbingPlan.segments(from: translation ?? source)
            .filter { $0.speaker != "Desconhecido" }
            .map { OriginalVoices.Line(id: $0.id, start: $0.start, end: $0.end, speaker: $0.speaker, text: source.plainText(at: $0.id)) }
        guard !lines.isEmpty else { return [] }
        let work = store.directory(for: project.id).appendingPathComponent("Dub", isDirectory: true)
        return try await OriginalVoices(tools: tools, workDirectory: work).samples(for: lines, media: info, audioTrack: audio) { value, message in
            progress(WorkflowStep(fraction: value, message: message))
        }
    }

    /// Gives every speaker without a voice one automatically: a clone of the original voice
    /// (VoiceStudio) or a macOS voice of similar pitch. Voices made by another engine are replaced.
    public func automaticCast(_ project: StudioProject, cast: VoiceCast, systemVoices: Set<String>, audioTrackID: Int? = nil,
                              progress: @escaping @Sendable (WorkflowStep) -> Void) async throws -> VoiceCast {
        let samples = try await voiceSamples(project, audioTrackID: audioTrackID, progress: progress)
        var cast = cast
        cast.addMissing(from: samples.map(\.speaker))
        let engine = settings.dubbingEngine.rawValue
        let needing = samples.filter { sample in
            guard let member = cast.member(for: sample.speaker) else { return true }
            return member.voiceID == nil || member.engine != engine
        }
        guard !needing.isEmpty else { return cast }
        let assigned: [String: String]
        switch settings.dubbingEngine {
        case .voiceStudio:
            progress(WorkflowStep(fraction: 0.95, message: "Clonando as vozes originais no VoiceStudio…"))
            assigned = try await AutoCasting.clonedVoices(for: needing, client: VoiceStudioClient(baseURL: settings.voiceStudioURL),
                                                          prefix: project.title, language: settings.sourceLanguage)
        case .original:
            // The voice is the character's own clip: PocketTTS clones it on the Mac.
            assigned = Dictionary(needing.map { ($0.speaker, $0.url.path) }, uniquingKeysWith: { a, _ in a })
        case .system:
            assigned = AutoCasting.systemVoices(for: needing, available: systemVoices)
        }
        for i in cast.members.indices {
            if let voice = assigned[cast.members[i].name] {
                cast.members[i].voiceID = voice
                cast.members[i].engine = engine
            }
        }
        return cast
    }

    /// Writes the edited original subtitle back into the MKV in place of its old version
    /// (same language, name and flags), in a new file or in the file itself.
    public func saveEditedSubtitle(_ project: StudioProject, replaceOriginal: Bool,
                                   progress: @escaping @Sendable (WorkflowStep) -> Void) async throws -> (StudioProject, URL, VerificationReport) {
        var project = project
        guard let sourceURL = store.sourceSubtitleURL(for: project), FileManager.default.fileExists(atPath: sourceURL.path) else { throw WorkflowError.noTextSubtitle }
        let info = try await MediaInspector(tools: tools).inspect(project.mediaURL)
        let old = project.sourceTrackID.flatMap { id in info.tracks.first { $0.id == id } }
        let track = NewTrack(file: sourceURL, kind: .subtitles, language: old?.languageIETF ?? old?.language ?? settings.targetLanguage,
                             name: old?.name ?? sourceURL.deletingPathExtension().lastPathComponent, isDefault: old?.isDefault ?? false, isForced: old?.isForced ?? false)
        var plan = MuxPlan(source: info, output: MuxPlan.defaultOutputURL(for: project.mediaURL, suffix: "editado"),
                           newTracks: [track], clearOtherDefaults: track.isDefault, placeNewTracksFirst: false)
        if let old { plan.excludedTrackIDs = [old.id] }
        plan.replaceSource = replaceOriginal
        let (url, report) = try await MKVMuxer(tools: tools).mux(plan) { value in
            progress(WorkflowStep(fraction: value, message: value < 0.9 ? "Gravando o MKV…" : "Verificando integridade…"))
        }
        if replaceOriginal {
            project.sourceTrackID = report.outputInfo?.tracks(.subtitles).first { $0.name == track.name && ($0.languageIETF == track.language || $0.language == old?.language) }?.id
            project.mediaFingerprint = Self.fingerprint(of: url)
        }
        project.lastOutputPath = url.path
        project.lastVerification = report
        try store.save(project)
        return (project, url, report)
    }

    /// Work files of the episode's dub (synthesized lines, voices, separated audio).
    public func dubWorkDirectory(_ project: StudioProject) -> URL {
        store.directory(for: project.id).appendingPathComponent("Dub", isDirectory: true)
    }

    /// Voice-over dub: synthesizes the translated lines with the cast, mixes them over the
    /// original audio, and writes a new MKV with the dubbed audio and the translated subtitle
    /// added (all original tracks kept, video not re-encoded).
    public func dub(_ project: StudioProject, synthesizer: any SpeechSynthesizer, cast: VoiceCast, replaceOriginal: Bool = false, audioTrackID: Int? = nil,
                    progress: @escaping @Sendable (WorkflowStep) -> Void) async throws -> (StudioProject, URL, DubbingReport, VerificationReport) {
        var project = project
        guard let translationURL = store.translationURL(for: project, language: settings.targetLanguage),
              let translation = try? SubtitleDocument.load(translationURL) else { throw WorkflowError.notTranslated }
        progress(WorkflowStep(fraction: 0.01, message: "Analisando faixas…"))
        let info = try await MediaInspector(tools: tools).inspect(project.mediaURL)
        guard let audio = audioTrackID.flatMap({ id in info.tracks.first { $0.id == id } }) ?? info.tracks(.audio).first(where: \.isDefault) ?? info.tracks(.audio).first
        else { throw WorkflowError.noAudio }
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
        var plan = MuxPlan(source: info, output: MuxPlan.defaultOutputURL(for: project.mediaURL, suffix: "\(settings.targetLanguage.uppercased()) DUB"),
                           newTracks: tracks, clearOtherDefaults: settings.makeDefault, placeNewTracksFirst: settings.placeNewTrackFirst)
        plan.replaceSource = replaceOriginal
        AppLog.shared.info("Dublagem: \(segments.count) falas, \(report.synthesized) geradas, \(report.failed.count) sem voz; gravando em \(replaceOriginal ? "o próprio arquivo" : plan.output.lastPathComponent)")
        let (url, verification) = try await MKVMuxer(tools: tools).mux(plan) { value in
            progress(WorkflowStep(fraction: 0.85 + value * 0.15, message: value < 0.9 ? "Gravando novo MKV…" : "Verificando integridade…"))
        }
        project.dubbingStatus = report.failed.isEmpty ? .muxed : .failed
        project.lastDubReport = report
        if replaceOriginal { project.mediaFingerprint = Self.fingerprint(of: url) }
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
