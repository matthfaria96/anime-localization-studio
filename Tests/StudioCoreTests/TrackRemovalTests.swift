import Foundation
import MediaKit
import SubtitleKit
import Testing
import TranslationKit
@testable import StudioCore

private let tools = ToolLocator()
private let canRun = [ExternalTool.mkvmerge, .mkvextract, .ffmpeg, .ffprobe].allSatisfy { tools.locate($0) != nil }

@Suite("Removing tracks (real tools)", .enabled(if: canRun))
struct TrackRemovalTests {
    @Test func removesASubtitleAndItsOnlyFontAndKeepsReferencesRight() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ALSRemove-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = AppPaths(root: base.appendingPathComponent("Support"), caches: base.appendingPathComponent("Caches"))
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let raw = base.appendingPathComponent("raw.mkv")
        try await ProcessRunner.runChecked(try tools.require(.ffmpeg), ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=160x90:rate=24:duration=3",
                                                                       "-f", "lavfi", "-i", "sine=frequency=330:duration=3",
                                                                       "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac", raw.path])
        func ass(_ text: String) -> String {
            "[Script Info]\nScriptType: v4.00+\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:00.50,0:00:02.00,Default,,0,0,0,,\(text)\n"
        }
        let en = base.appendingPathComponent("en.ass"), pt = base.appendingPathComponent("pt.ass")
        try ass("Hello").write(to: en, atomically: true, encoding: .utf8)
        try ass("Olá").write(to: pt, atomically: true, encoding: .utf8)
        let font = base.appendingPathComponent("Only-English.ttf")
        try Data(contentsOf: URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial.ttf")).write(to: font)
        let episode = base.appendingPathComponent("Show - 10.mkv")
        try await ProcessRunner.runChecked(try tools.require(.mkvmerge), ["-o", episode.path, raw.path, "--language", "0:en", en.path,
                                                                          "--language", "0:pt-BR", pt.path, "--attach-file", font.path],
                                           acceptedExitCodes: [0, 1])
        let info = try await MediaInspector(tools: tools).inspect(episode)
        let subtitles = info.tracks(.subtitles)
        let english = try #require(subtitles.first), portuguese = try #require(subtitles.last)
        var project = ProjectStore(paths: paths).project(for: episode)
        project.sourceTrackID = portuguese.id
        project.referenceTrackID = english.id
        let workflow = EpisodeWorkflow(paths: paths, settings: AppSettings(), engine: AppleTranslationEngine(), glossary: Glossary())

        let (updated, url, report) = try await workflow.removeTracks(project, trackIDs: [english.id],
                                                                      attachmentIDs: Set(info.attachments.map(\.id)), replaceOriginal: true) { _ in }
        #expect(report.passed, "\(report.failures)")
        #expect(url.path == episode.path, "written into the file itself")
        let after = try await MediaInspector(tools: tools).inspect(episode)
        #expect(after.tracks(.subtitles).count == 1 && after.attachments.isEmpty)
        // The Portuguese subtitle moved to another number; the project follows it.
        let kept = try #require(after.tracks(.subtitles).first)
        #expect(updated.sourceTrackID == kept.id && kept.language == "por")
        #expect(updated.referenceTrackID == nil, "the removed track is no longer referenced")
    }
}
