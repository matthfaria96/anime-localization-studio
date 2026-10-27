import CryptoKit
import Foundation
import MediaKit
import SubtitleKit
import Testing
import TranslationKit
@testable import StudioCore

private let tools = ToolLocator()
private let canRun = [ExternalTool.mkvmerge, .mkvextract, .ffmpeg, .ffprobe].allSatisfy { tools.locate($0) != nil }

@Suite("Edit an existing subtitle (real tools)", .enabled(if: canRun))
struct EditSubtitleWorkflowTests {
    @Test func correctedSubtitleReplacesItsTrackInANewFile() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ALSEditFlow-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = AppPaths(root: base.appendingPathComponent("Support"), caches: base.appendingPathComponent("Caches"))
        let media = base.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let raw = media.appendingPathComponent("raw.mkv")
        try await ProcessRunner.runChecked(try tools.require(.ffmpeg), [
            "-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=24:duration=3",
            "-f", "lavfi", "-i", "sine=frequency=330:duration=3", "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
            "-c:a", "aac", raw.path])
        let ass = media.appendingPathComponent("en.ass")
        try """
        [Script Info]
        ScriptType: v4.00+

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:00.50,0:00:02.00,Default,,0,0,0,,Helo wrold

        """.write(to: ass, atomically: true, encoding: .utf8)
        let episode = media.appendingPathComponent("Episode 02.mkv")
        try await ProcessRunner.runChecked(try tools.require(.mkvmerge), ["-o", episode.path, raw.path,
                                                                          "--language", "0:en", "--track-name", "0:English", "--default-track-flag", "0:yes", ass.path],
                                           acceptedExitCodes: [0, 1])
        let originalHash = SHA256.hash(data: try Data(contentsOf: episode))

        let workflow = EpisodeWorkflow(paths: paths, settings: AppSettings(), engine: AppleTranslationEngine(), glossary: Glossary())
        let store = ProjectStore(paths: paths)
        var (project, _, sourceURL) = try await workflow.prepareSource(store.project(for: episode))
        project.subtitleTask = .edit
        var edited = try SubtitleDocument.load(sourceURL)
        edited.setRawText("Hello world", at: 0)
        try edited.write(to: sourceURL)

        let (_, output, report) = try await workflow.saveEditedSubtitle(project, replaceOriginal: false) { _ in }
        #expect(report.passed, "\(report.failures)")
        #expect(output.lastPathComponent == "Episode 02 [editado].mkv")
        let info = try #require(report.outputInfo)
        let subtitles = info.tracks(.subtitles)
        #expect(subtitles.count == 1, "the corrected track takes the old one's place")
        #expect(subtitles.first?.name == "English" && subtitles.first?.isDefault == true)
        let check = base.appendingPathComponent("check.ass")
        _ = try await TrackExtractor(tools: tools).extractSubtitle(try #require(subtitles.first), from: info, to: check)
        #expect(try String(contentsOf: check, encoding: .utf8).contains("Hello world"))
        #expect(SHA256.hash(data: try Data(contentsOf: episode)) == originalHash, "the original is untouched")
    }
}
