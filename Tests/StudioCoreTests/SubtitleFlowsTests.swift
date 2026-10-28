import DubbingKit
import Foundation
import MediaKit
import SubtitleKit
import Testing
import TranslationKit
@testable import StudioCore

private let tools = ToolLocator()
private let canRun = [ExternalTool.mkvmerge, .mkvextract, .ffmpeg, .ffprobe].allSatisfy { tools.locate($0) != nil }

/// A stand-in for the translation engines: a fixed dictionary, so the test checks the flow
/// (extract → translate → write into the video → export), not translation quality.
private struct DictionaryEngine: TranslationEngine {
    let id = "dictionary", displayName = "Dicionário", keepsPlaceholders = true, usesContext = false, preferredBatchSize = 10
    let words: [String: String]
    func availability(source: String?, target: String) async -> EngineAvailability { .available }
    func translate(_ lines: [TranslationLine], context: TranslationContext) async throws -> [Int: String] {
        Dictionary(uniqueKeysWithValues: lines.map { ($0.id, words[$0.text] ?? $0.text) })
    }
}

/// The two ways of making a new subtitle that the person asked about, end to end with the
/// real tools: from the speech of the video, and translated from another subtitle.
@Suite("New subtitles end to end (real tools)", .enabled(if: canRun), .serialized)
struct SubtitleFlowsTests {
    private func workspace() throws -> (URL, AppPaths) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ALSFlows-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Media"), withIntermediateDirectories: true)
        return (base, AppPaths(root: base.appendingPathComponent("Support"), caches: base.appendingPathComponent("Caches")))
    }

    @Test func subtitleFromTheAudioAloneIsWrittenIntoTheVideo() async throws {
        try #require(await SpeechTranscription.isReady(language: "en-US") == true, "modelo de fala em inglês não instalado neste Mac")
        let (base, paths) = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let ffmpeg = try tools.require(.ffmpeg)
        let speech = base.appendingPathComponent("speech.wav")
        try await ProcessRunner.runChecked(URL(fileURLWithPath: "/usr/bin/say"), ["-o", speech.path, "--file-format=WAVE", "--data-format=LEI16@16000",
                                                                                 "I won't let you hurt my friends. We have to reach the top floor."])
        // A video with speech and no subtitle at all.
        let episode = base.appendingPathComponent("Media/Episode 03.mkv")
        try await ProcessRunner.runChecked(ffmpeg, ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=24:duration=8",
                                                    "-i", speech.path, "-af", "adelay=1000", "-shortest", "-c:v", "libx264", "-preset", "ultrafast",
                                                    "-pix_fmt", "yuv420p", "-c:a", "aac", episode.path])
        let workflow = EpisodeWorkflow(paths: paths, settings: AppSettings(), engine: AppleTranslationEngine(), glossary: Glossary())
        let store = ProjectStore(paths: paths)

        var project = try await workflow.transcribe(store.project(for: episode), language: "en-US", allowModelDownload: false) { _ in }
        project.subtitleTask = .edit
        let source = try SubtitleDocument.load(try #require(store.sourceSubtitleURL(for: project)))
        let heard = source.cues.map(\.plainText).joined(separator: " ").lowercased()
        #expect(heard.contains("top floor"), "\(heard)")
        #expect(source.cues.first.map { $0.start >= 800 } == true, "timed to the speech")

        let (_, output, report) = try await workflow.saveEditedSubtitle(project, replaceOriginal: false) { _ in }
        #expect(report.passed, "\(report.failures)")
        let track = try #require(report.outputInfo?.tracks(.subtitles).first)
        #expect(track.language == "eng" || track.languageIETF?.hasPrefix("en") == true, "the track is in the language spoken")
        let check = base.appendingPathComponent("check.srt")
        _ = try await TrackExtractor(tools: tools).extractSubtitle(track, from: try #require(report.outputInfo), to: check)
        #expect(try String(contentsOf: check, encoding: .utf8).lowercased().contains("top floor"))
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test func subtitleTranslatedFromAnotherIsWrittenIntoTheVideoAndExported() async throws {
        let (base, paths) = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let raw = base.appendingPathComponent("Media/raw.mkv")
        try await ProcessRunner.runChecked(try tools.require(.ffmpeg), [
            "-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=24:duration=4",
            "-f", "lavfi", "-i", "sine=frequency=330:duration=4", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
            "-c:a", "aac", raw.path])
        let ass = base.appendingPathComponent("Media/en.ass")
        try """
        [Script Info]
        ScriptType: v4.00+

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,48,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,1,2,10,10,10,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:00.50,0:00:01.50,Default,Kirito,0,0,0,,{\\an8}Good morning
        Dialogue: 0,0:00:02.00,0:00:03.50,Default,Asuna,0,0,0,,See you {\\i1}tomorrow{\\i0}

        """.write(to: ass, atomically: true, encoding: .utf8)
        let episode = base.appendingPathComponent("Media/Episode 04.mkv")
        try await ProcessRunner.runChecked(try tools.require(.mkvmerge), ["-o", episode.path, raw.path, "--language", "0:en", "--track-name", "0:English", ass.path],
                                           acceptedExitCodes: [0, 1])
        let engine = DictionaryEngine(words: ["Good morning": "Bom dia", "See you ⟦1⟧tomorrow": "Até ⟦1⟧amanhã"])
        let workflow = EpisodeWorkflow(paths: paths, settings: AppSettings(), engine: engine, glossary: Glossary())
        let store = ProjectStore(paths: paths)
        var project = store.project(for: episode)
        project.subtitleTask = .translate

        let (translated, translationReport) = try await workflow.translate(project) { _ in }
        #expect(translationReport.isComplete)
        let translationURL = try #require(store.translationURL(for: translated, language: "pt-BR"))
        let translation = try SubtitleDocument.load(translationURL)
        #expect(translation.rawText(at: 0) == "{\\an8}Bom dia", "position tag kept")
        #expect(translation.rawText(at: 1) == "Até {\\i1}amanhã{\\i0}", "inline tags kept: \(translation.rawText(at: 1))")
        #expect(translation.cues.map(\.actor) == ["Kirito", "Asuna"], "characters kept")

        let (_, output, report) = try await workflow.mux(translated, replaceOriginal: false) { _ in }
        #expect(report.passed, "\(report.failures)")
        #expect(output.lastPathComponent == "Episode 04 [PT-BR].mkv")
        let subtitles = try #require(report.outputInfo).tracks(.subtitles)
        #expect(subtitles.count == 2, "the original subtitle stays")
        let added = try #require(subtitles.first { $0.languageIETF == "pt-BR" || $0.language == "por" })
        let check = base.appendingPathComponent("check.ass")
        _ = try await TrackExtractor(tools: tools).extractSubtitle(added, from: try #require(report.outputInfo), to: check)
        #expect(try String(contentsOf: check, encoding: .utf8).contains("Até {\\i1}amanhã{\\i0}"))

        // “Salvar como arquivo de legenda…” writes the same document to a file of its own.
        let exported = base.appendingPathComponent("Episode 04.pt-BR.ass")
        try translation.write(to: exported)
        #expect(try SubtitleDocument.load(exported).rawText(at: 0) == "{\\an8}Bom dia")
    }
}
