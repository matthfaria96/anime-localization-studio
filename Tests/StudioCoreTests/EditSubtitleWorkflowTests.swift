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

        // A subtitle written from scratch becomes a new track named after its language.
        var blank = try await workflow.startBlankSubtitle(project, language: "pt-BR")
        blank.subtitleTask = .edit
        let blankURL = try #require(store.sourceSubtitleURL(for: blank))
        var written = try SubtitleDocument.load(blankURL)
        #expect(written.count == 1)
        written.setRawText("Olá mundo", at: 0)
        try written.write(to: blankURL)
        let (_, withNew, newReport) = try await workflow.saveEditedSubtitle(blank, replaceOriginal: false) { _ in }
        #expect(newReport.passed, "\(newReport.failures)")
        let tracks = try #require(newReport.outputInfo).tracks(.subtitles)
        #expect(tracks.count == 2, "the English track stays; the new one is added")
        #expect(tracks.contains { $0.name == "Português (Brasil)" && ($0.languageIETF == "pt-BR" || $0.language == "por") })
        #expect(withNew != output)
    }

    @Test func choosingAnotherTrackReallyLoadsIt() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ALSSwitch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = AppPaths(root: base.appendingPathComponent("Support"), caches: base.appendingPathComponent("Caches"))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let raw = base.appendingPathComponent("raw.mkv")
        try await ProcessRunner.runChecked(try tools.require(.ffmpeg), ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=24:duration=3",
                                                                       "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", raw.path])
        func ass(_ text: String) -> String {
            "[Script Info]\nScriptType: v4.00+\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:00.50,0:00:02.00,Default,,0,0,0,,\(text)\n"
        }
        let en = base.appendingPathComponent("en.ass"), pt = base.appendingPathComponent("pt.ass")
        try ass("Hello").write(to: en, atomically: true, encoding: .utf8)
        try ass("Olá").write(to: pt, atomically: true, encoding: .utf8)
        let episode = base.appendingPathComponent("Show - 09.mkv")
        try await ProcessRunner.runChecked(try tools.require(.mkvmerge), ["-o", episode.path, raw.path, "--language", "0:en", en.path, "--language", "0:pt-BR", pt.path],
                                           acceptedExitCodes: [0, 1])
        let info = try await MediaInspector(tools: tools).inspect(episode)
        let tracks = info.tracks(.subtitles)
        let workflow = EpisodeWorkflow(paths: paths, settings: AppSettings(), engine: AppleTranslationEngine(), glossary: Glossary())
        let store = ProjectStore(paths: paths)
        var project = store.project(for: episode)
        project.sourceTrackID = tracks[0].id
        var (prepared, _, url) = try await workflow.prepareSource(project)
        #expect(try SubtitleDocument.load(url).plainText(at: 0) == "Hello")
        // What the Legendar picker does: the choice changes before the file is prepared.
        prepared.sourceTrackID = tracks[1].id
        (prepared, _, url) = try await workflow.prepareSource(prepared)
        #expect(try SubtitleDocument.load(url).plainText(at: 0) == "Olá", "the chosen track is loaded, not the old file")
        #expect(prepared.sourceFileTrackID == tracks[1].id)
    }
}
