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

    public var errorDescription: String? {
        switch self {
        case .noTextSubtitle: "O arquivo não tem legenda de texto (ASS, SSA ou SRT) para traduzir. Abra uma legenda externa no editor."
        case .bitmapOnly: "As legendas deste arquivo são imagens (PGS/VobSub) e precisam de OCR, que ainda não está implementado."
        case .notTranslated: "Traduza o episódio antes de dublar: a dublagem usa as falas da tradução e os tempos da legenda."
        case .noAudio: "O arquivo não tem faixa de áudio para servir de base à dublagem."
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
        let changedTrack = project.sourceTrackID != track.id || project.sourceFormat != format
        project.sourceTrackID = track.id
        project.sourceFormat = format
        let url = store.sourceSubtitleURL(for: project)!
        if changedTrack || !FileManager.default.fileExists(atPath: url.path) {
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
        let pipeline = TranslationPipeline(engine: engine, glossary: glossary, options: settings.translationOptions, checkpointURL: checkpoint)
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
                                       options: DubbingOptions(maxSpeedup: settings.dubbingMaxSpeedup, defaultVoice: settings.dubbingDefaultVoice))
        let report = try await pipeline.run(segments, media: info, audioTrack: audio, output: dubAudio) { value, message in
            progress(WorkflowStep(fraction: value * 0.85, message: message))
        }
        let localized = Locale(identifier: "pt_BR").localizedString(forIdentifier: settings.targetLanguage) ?? settings.targetLanguage
        let languageName = localized.prefix(1).uppercased() + localized.dropFirst()
        let tracks = [
            NewTrack(file: dubAudio, kind: .audio, language: settings.targetLanguage, name: "\(languageName) · dublagem IA (voice-over)", isDefault: settings.makeDefault),
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

    private var preferredSourceLanguages: [String] {
        var languages = ["eng", "en", "jpn", "ja"]
        if let source = settings.sourceLanguage {
            languages.insert(contentsOf: [source, IntegrityVerifier.iso6392(for: source)], at: 0)
        }
        return languages
    }
}
