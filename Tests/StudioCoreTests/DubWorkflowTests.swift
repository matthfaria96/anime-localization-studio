import AVFoundation
import CryptoKit
import DubbingKit
import Foundation
import MediaKit
import SubtitleKit
import Testing
import TranslationKit
@testable import StudioCore

private let tools = ToolLocator()
private let canRun = [ExternalTool.mkvmerge, .mkvextract, .ffmpeg, .ffprobe].allSatisfy { tools.locate($0) != nil }
    && AVSpeechSynthesisVoice.speechVoices().contains { $0.name == "Luciana" }

@Suite("Dub workflow (real tools)", .enabled(if: canRun))
struct DubWorkflowTests {
    @Test func dubsIntoANewMKVKeepingEveryOriginalTrack() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ALSDubFlow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = AppPaths(root: base.appendingPathComponent("Support"), caches: base.appendingPathComponent("Caches"))
        let media = base.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let raw = media.appendingPathComponent("raw.mkv")
        try await ProcessRunner.runChecked(try tools.require(.ffmpeg), [
            "-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24:duration=5",
            "-f", "lavfi", "-i", "sine=frequency=330:duration=5", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
            "-c:a", "aac", raw.path])
        let ass = media.appendingPathComponent("en.ass")
        try """
        [Script Info]
        ScriptType: v4.00+

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:00.50,0:00:02.50,Default,Kirito,0,0,0,,I won't let you hurt my friends!
        Dialogue: 0,0:00:03.00,0:00:04.50,Default,Asuna,0,0,0,,Wait!

        """.write(to: ass, atomically: true, encoding: .utf8)
        let episode = media.appendingPathComponent("Episode 01.mkv")
        try await ProcessRunner.runChecked(try tools.require(.mkvmerge), ["-o", episode.path, "--language", "1:ja", raw.path, "--language", "0:en", ass.path],
                                           acceptedExitCodes: [0, 1])
        let originalHash = SHA256.hash(data: try Data(contentsOf: episode))

        var settings = AppSettings()
        settings.engine = .appleTranslation
        let workflow = EpisodeWorkflow(paths: paths, settings: settings, engine: AppleTranslationEngine(), glossary: Glossary())
        let store = ProjectStore(paths: paths)
        let (project, _, sourceURL) = try await workflow.prepareSource(store.project(for: episode))
        var translation = try SubtitleDocument.load(sourceURL)
        translation.setRawText("Eu não vou deixar você machucar meus amigos!", at: 0)
        translation.setRawText("Espera!", at: 1)
        try translation.write(to: try #require(store.translationURL(for: project)))

        let cast = VoiceCast(members: [CastMember(name: "Kirito", voiceID: "Luciana"), CastMember(name: "Asuna", voiceID: "Luciana")])
        let (updated, output, report, verification) = try await workflow.dub(project, synthesizer: SystemVoiceSynthesizer(), cast: cast) { _ in }
        #expect(report.failed.isEmpty && report.synthesized == 2)
        #expect(verification.passed, "\(verification.failures)")
        #expect(output.lastPathComponent == "Episode 01 [PT-BR DUB].mkv")
        #expect(updated.dubbingStatus == .muxed)
        let result = try #require(verification.outputInfo)
        #expect(result.tracks(.audio).count == 2)
        #expect(result.tracks(.audio).contains { $0.languageIETF == "pt-BR" && $0.isDefault })
        #expect(result.tracks(.audio).contains { $0.languageIETF == "ja" && !$0.isDefault })
        #expect(result.tracks(.subtitles).count == 2)
        #expect(SHA256.hash(data: try Data(contentsOf: episode)) == originalHash)
    }
}
