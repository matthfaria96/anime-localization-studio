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

    var tools: ToolLocator { settings.toolLocator }
    var store: ProjectStore { ProjectStore(paths: paths) }

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
        // Compare with the track the file came from, not with the choice (which already changed).
        // Projects from before this field: an unsaved draft is assumed to match; otherwise the
        // file is extracted again once, to be sure.
        let fileTrack = project.sourceFileTrackID ?? (project.draftPending == true ? project.sourceTrackID : nil)
        let changedTrack = fileTrack != track.id || project.sourceFormat != format || mediaReplaced
        project.mediaFingerprint = fingerprint
        project.sourceTrackID = track.id
        project.sourceFormat = format
        let url = store.sourceSubtitleURL(for: project)!
        if changedTrack || !FileManager.default.fileExists(atPath: url.path) {
            // A new release at the same path may have new timing: keep a copy of the old work.
            if mediaReplaced { try? store.backupTranslation(of: project, language: settings.targetLanguage) }
            _ = try await TrackExtractor(tools: tools).extractSubtitle(track, from: info, to: url)
            project.sourceFileTrackID = track.id
            if project.translationStatus == .new { project.translationStatus = .extracted }
            try store.save(project)
        } else if project.sourceFileTrackID == nil {
            project.sourceFileTrackID = track.id
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
        progress(WorkflowStep(fraction: 0.02, message: "Preparando a gravação…"))
        let info = try await MediaInspector(tools: tools).inspect(project.mediaURL)
        let track = NewTrack(file: translation, kind: .subtitles, language: settings.targetLanguage, name: settings.trackName,
                             isDefault: settings.makeDefault)
        var plan = MuxPlan(source: info, output: MuxPlan.defaultOutputURL(for: project.mediaURL, suffix: settings.targetLanguage.uppercased()),
                           newTracks: [track], clearOtherDefaults: settings.makeDefault, placeNewTracksFirst: settings.placeNewTrackFirst)
        plan.replaceSource = replaceOriginal
        plan.attachments = store.addedFontURLs(for: project)
        let (url, report) = try await MKVMuxer(tools: tools).mux(plan) { value in
            progress(WorkflowStep(fraction: value, message: value < 0.9 ? "Gravando novo MKV…" : "Verificando integridade…"))
        }
        project.translationStatus = .muxed
        project.lastOutputPath = url.path
        project.lastVerification = report
        if replaceOriginal {
            // Track ids can shift in the rewritten file; every reference follows its track.
            if let output = report.outputInfo { Self.remapTrackIDs(&project, from: info, removed: [], to: output) }
            project.mediaFingerprint = Self.fingerprint(of: url)
        }
        try store.save(project)
        return (project, url, report)
    }


    /// “Japonês”, “Português (Brasil)”: how players name a track in that language.
    public static func trackName(for language: String) -> String {
        let name = Locale(identifier: "pt_BR").localizedString(forIdentifier: language) ?? language
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// A blank subtitle (one empty line) to write from scratch, sized to the video.
    public func startBlankSubtitle(_ project: StudioProject, language: String, name: String? = nil) async throws -> StudioProject {
        var project = project
        let info = try await MediaInspector(tools: tools).inspect(project.mediaURL)
        let video = info.tracks(.video).first
        let document = SubtitleDocument.ass(ASSDocument.make(events: [(start: 0, end: 2_000, text: "", actor: "")],
                                                             playResX: video?.width ?? 1920, playResY: video?.height ?? 1080))
        let url = store.directory(for: project.id).appendingPathComponent("source.ass")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let old = store.translationURL(for: project, language: settings.targetLanguage), FileManager.default.fileExists(atPath: old.path) {
            try? store.backupTranslation(of: project, language: settings.targetLanguage)
        }
        try document.write(to: url)
        project.externalSubtitlePath = url.path
        project.sourceFormat = .ass
        project.sourceTrackID = nil
        project.referenceTrackID = nil
        project.newTrackLanguage = language
        project.newTrackName = name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0.trimmingCharacters(in: .whitespaces) }
        project.draftPending = true
        try store.save(project)
        return project
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
                           identifySpeakers: Bool = false, allowDiarizationDownload: Bool = false, audioTrackID: Int? = nil,
                           progress: @escaping @Sendable (WorkflowStep) -> Void) async throws -> StudioProject {
        var project = project
        progress(WorkflowStep(fraction: 0.01, message: "Analisando faixas…"))
        let info = try await MediaInspector(tools: tools).inspect(project.mediaURL)
        guard let audio = audioTrackID.flatMap({ id in info.tracks.first { $0.id == id } }) ?? info.tracks(.audio).first(where: \.isDefault) ?? info.tracks(.audio).first
        else { throw WorkflowError.noAudio }
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
            // Who speaks is kept in the project (for the dub), not written into the subtitle.
            let speakers = SpeakerDiarization.assign(turns, to: lines.map { ($0.start, $0.end) })
            project.autoSpeakers = (project.autoSpeakers ?? [:]).merging(["translation": Dictionary(uniqueKeysWithValues:
                speakers.enumerated().compactMap { n, name in name.map { (n, $0) } })]) { _, new in new }
            document = SpeechTranscription.document(from: lines, speakers: [])
        } else {
            document = SpeechTranscription.document(from: lines)
        }
        let url = directory.appendingPathComponent("source.\(document.format.fileExtension)")
        try document.write(to: url)
        project.externalSubtitlePath = url.path
        project.sourceFormat = document.format
        project.sourceTrackID = nil
        project.newTrackLanguage = language
        project.translationStatus = .extracted
        try store.save(project)
        return project
    }

    /// Speaker of each spoken line of an existing subtitle, from `audioTrackID` (the dub's base
    /// audio; the default track when nil). Comments, signs, drawings and karaoke are left alone.
    public func identifySpeakers(in document: SubtitleDocument, of project: StudioProject, audioTrackID: Int? = nil, allowModelDownload: Bool,
                                 progress: @escaping @Sendable (WorkflowStep) -> Void) async throws -> [Int: String] {
        let diarizer = SpeakerDiarization(modelsDirectory: paths.diarizationModels)
        guard diarizer.modelsInstalled || allowModelDownload else { throw SpeakerDiarization.DiarizationError.modelsNotInstalled }
        let info = try await MediaInspector(tools: tools).inspect(project.mediaURL)
        guard let audio = audioTrackID.flatMap({ id in info.tracks.first { $0.id == id } }) ?? info.tracks(.audio).first(where: \.isDefault)
                ?? info.tracks(.audio).first else { throw WorkflowError.noAudio }
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
        let spoken = DubbingPlan.segments(from: document.withSideSpeakers(project.lineSpeakers ?? [:]))
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
    public func voiceSamples(_ project: StudioProject, audioTrackID: Int? = nil, textTrackID: Int? = nil,
                             progress: @escaping @Sendable (WorkflowStep) -> Void) async throws -> [OriginalVoices.Sample] {
        let info = try await MediaInspector(tools: tools).inspect(project.mediaURL)
        guard let audio = audioTrackID.flatMap({ id in info.tracks.first { $0.id == id } }) ?? info.tracks(.audio).first(where: \.isDefault) ?? info.tracks(.audio).first
        else { throw WorkflowError.noAudio }
        let text = try await dubText(project, trackID: textTrackID, info: info)
        let lines = spokenSegments(text, project: project)
            .filter { $0.speaker != "Desconhecido" }
            .map { OriginalVoices.Line(id: $0.id, start: $0.start, end: $0.end, speaker: $0.speaker, text: $0.text) }
        guard !lines.isEmpty else { return [] }
        let work = dubWorkDirectory(project)
        return try await OriginalVoices(tools: tools, workDirectory: work).samples(for: lines, media: info, audioTrack: audio) { value, message in
            progress(WorkflowStep(fraction: value, message: message))
        }
    }

    /// Gives every speaker without a voice their own: the clip of their original voice, which
    /// Chatterbox clones on the Mac. Voices made by another engine are replaced.
    public func automaticCast(_ project: StudioProject, cast: VoiceCast, audioTrackID: Int? = nil, textTrackID: Int? = nil,
                              progress: @escaping @Sendable (WorkflowStep) -> Void) async throws -> VoiceCast {
        let samples = try await voiceSamples(project, audioTrackID: audioTrackID, textTrackID: textTrackID, progress: progress)
        var cast = cast
        cast.addMissing(from: samples.map(\.speaker))
        let engine = settings.dubbingEngine.rawValue
        let needing = samples.filter { sample in
            guard let member = cast.member(for: sample.speaker) else { return true }
            return member.voiceID == nil || member.engine != engine
        }
        guard !needing.isEmpty else { return cast }
        // By `member(for:)`, so a character renamed in Dublar (old name kept as an alias) is found.
        for sample in needing {
            guard let i = cast.members.firstIndex(where: { $0.id == cast.member(for: sample.speaker)?.id }),
                  cast.members[i].voiceID == nil || cast.members[i].engine != engine else { continue }
            cast.members[i].voiceID = sample.url.path
            cast.members[i].engine = engine
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
        // A subtitle that did not come from the video (blank, imported, transcribed) is a new track.
        let language = old?.languageIETF ?? old?.language ?? project.newTrackLanguage ?? settings.targetLanguage
        let track = NewTrack(file: sourceURL, kind: .subtitles, language: language,
                             name: old?.name ?? project.newTrackName ?? Self.trackName(for: language), isDefault: old?.isDefault ?? settings.makeDefault, isForced: old?.isForced ?? false)
        var plan = MuxPlan(source: info, output: MuxPlan.defaultOutputURL(for: project.mediaURL, suffix: "editado"),
                           newTracks: [track], clearOtherDefaults: track.isDefault, placeNewTracksFirst: false)
        if let old { plan.excludedTrackIDs = [old.id] }
        plan.replaceSource = replaceOriginal
        plan.attachments = store.addedFontURLs(for: project)
        let (url, report) = try await MKVMuxer(tools: tools).mux(plan) { value in
            progress(WorkflowStep(fraction: value, message: value < 0.9 ? "Gravando o MKV…" : "Verificando integridade…"))
        }
        if replaceOriginal, let output = report.outputInfo {
            Self.remapTrackIDs(&project, from: info, removed: plan.excludedTrackIDs, to: output)
            // The corrected subtitle is the new track that took the old one's place.
            let edited = output.tracks(.subtitles).first { $0.name == track.name && ($0.languageIETF == track.language || $0.language == old?.language) }?.id
            project.sourceTrackID = edited
            project.sourceFileTrackID = edited
            project.mediaFingerprint = Self.fingerprint(of: url)
        }
        project.lastOutputPath = url.path
        project.lastVerification = report
        try store.save(project)
        return (project, url, report)
    }

    /// Work files of the episode's dub (synthesized lines, voices, separated audio).
    func dubWorkDirectory(_ project: StudioProject) -> URL {
        store.directory(for: project.id).appendingPathComponent("Dub", isDirectory: true)
    }

    /// Voice-over dub: synthesizes the translated lines with the cast, mixes them over the
    /// original audio, and writes a new MKV with the dubbed audio and the translated subtitle
    /// added (all original tracks kept, video not re-encoded).
    /// Speaks `textTrackID` (a subtitle of the video) or, when nil, the app's translation, in that
    /// text's language. A subtitle already in the video is not added again.
    public func dub(_ project: StudioProject, synthesizer: any SpeechSynthesizer, cast: VoiceCast, replaceOriginal: Bool = false, audioTrackID: Int? = nil,
                    textTrackID: Int? = nil,
                    progress: @escaping @Sendable (WorkflowStep) -> Void) async throws -> (StudioProject, URL, DubbingReport, VerificationReport) {
        var project = project
        progress(WorkflowStep(fraction: 0.01, message: "Analisando faixas…"))
        let info = try await MediaInspector(tools: tools).inspect(project.mediaURL)
        guard let audio = audioTrackID.flatMap({ id in info.tracks.first { $0.id == id } }) ?? info.tracks(.audio).first(where: \.isDefault) ?? info.tracks(.audio).first
        else { throw WorkflowError.noAudio }
        let text = try await dubText(project, trackID: textTrackID, info: info)
        let language = text.language
        let segments = spokenSegments(text, project: project)
        let work = dubWorkDirectory(project)
        let dubAudio = store.directory(for: project.id).appendingPathComponent("dub.\(language).m4a")
        var lineVoices: [Int: String] = [:]
        if settings.dubbingEngine == .original && settings.dubbingPerLineVoice {
            // Each line is cloned from its own original audio: same voice, same emotion.
            let lines = segments.map { OriginalVoices.Line(id: $0.id, start: $0.start, end: $0.end, speaker: $0.speaker, text: "") }
            lineVoices = try await OriginalVoices(tools: tools, workDirectory: work).lineClips(for: lines, media: info, audioTrack: audio) { value, message in
                progress(WorkflowStep(fraction: value * 0.05, message: message))
            }.mapValues(\.path)
        }
        let pipeline = DubbingPipeline(synthesizer: synthesizer, tools: tools, workDirectory: work, cast: cast,
                                       options: DubbingOptions(maxSpeedup: settings.dubbingMaxSpeedup, defaultVoice: nil,
                                                               mode: settings.dubbingMode, lineVoices: lineVoices))
        let report = try await pipeline.run(segments, media: info, audioTrack: audio, output: dubAudio) { value, message in
            progress(WorkflowStep(fraction: value * 0.85, message: message))
        }
        var tracks = [NewTrack(file: dubAudio, kind: .audio, language: language,
                               name: "\(Self.trackName(for: language)) · dublagem IA (\(settings.dubbingMode.trackSuffix))", isDefault: settings.makeDefault)]
        // The translation goes in with its dub; a subtitle of the video is already there.
        if !text.isVideoTrack {
            tracks.append(NewTrack(file: text.file, kind: .subtitles, language: language, name: settings.trackName, isDefault: settings.makeDefault))
        }
        var plan = MuxPlan(source: info, output: MuxPlan.defaultOutputURL(for: project.mediaURL, suffix: "\(language.uppercased()) DUB"),
                           newTracks: tracks, clearOtherDefaults: settings.makeDefault, placeNewTracksFirst: settings.placeNewTrackFirst)
        plan.replaceSource = replaceOriginal
        plan.attachments = store.addedFontURLs(for: project)
        AppLog.shared.info("Dublagem: \(segments.count) falas, \(report.synthesized) geradas, \(report.failed.count) sem voz; gravando em \(replaceOriginal ? "o próprio arquivo" : plan.output.lastPathComponent)")
        let (url, verification) = try await MKVMuxer(tools: tools).mux(plan) { value in
            progress(WorkflowStep(fraction: 0.85 + value * 0.15, message: value < 0.9 ? "Gravando novo MKV…" : "Verificando integridade…"))
        }
        project.dubbingStatus = report.failed.isEmpty ? .muxed : .failed
        project.lastDubReport = report
        if replaceOriginal {
            if let output = verification.outputInfo { Self.remapTrackIDs(&project, from: info, removed: [], to: output) }
            project.mediaFingerprint = Self.fingerprint(of: url)
        }
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
