import CryptoKit
import Foundation
@testable import MediaKit

let testTools = ToolLocator()
let hasMediaTools = [ExternalTool.mkvmerge, .mkvextract, .ffmpeg, .ffprobe].allSatisfy { testTools.locate($0) != nil }

/// Builds a small but complete episode: H.264 video, two audio tracks (jpn default, eng),
/// an English ASS track, an embedded font and chapters — the shape of a typical fansub release.
enum MediaFixtures {
    static let ass = """
    [Script Info]
    ScriptType: v4.00+
    PlayResX: 640
    PlayResY: 360

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Arial,28,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,1,2,20,20,20,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:00.20,0:00:01.40,Default,Kirito,0,0,0,,I won't let you hurt my friends!
    Dialogue: 0,0:00:01.50,0:00:02.80,Default,Asuna,0,0,0,,{\\an8}Wait, {\\i1}where{\\i0} are you going?

    """

    static func makeEpisode(in directory: URL) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let ffmpeg = try testTools.require(.ffmpeg)
        let mkvmerge = try testTools.require(.mkvmerge)
        let base = directory.appendingPathComponent("base.mkv")
        try await ProcessRunner.runChecked(ffmpeg, [
            "-nostdin", "-v", "error", "-y",
            "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=24:duration=3",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=3",
            "-f", "lavfi", "-i", "sine=frequency=660:duration=3",
            "-map", "0:v", "-map", "1:a", "-map", "2:a",
            "-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k",
            base.path])
        let subs = directory.appendingPathComponent("eng.ass")
        try ass.write(to: subs, atomically: true, encoding: .utf8)
        let chapters = directory.appendingPathComponent("chapters.txt")
        try "CHAPTER01=00:00:00.000\nCHAPTER01NAME=Abertura\nCHAPTER02=00:00:01.500\nCHAPTER02NAME=Parte A\n"
            .write(to: chapters, atomically: true, encoding: .utf8)
        let episode = directory.appendingPathComponent("Episode 01 – teste ['$&].mkv")
        try await ProcessRunner.runChecked(mkvmerge, [
            "-o", episode.path,
            "--language", "1:ja", "--track-name", "1:Japonês", "--default-track-flag", "1:1",
            "--language", "2:en", "--track-name", "2:Inglês", "--default-track-flag", "2:0",
            base.path,
            "--language", "0:en", "--track-name", "0:English (Full)", "--default-track-flag", "0:1", subs.path,
            "--attachment-mime-type", "font/ttf", "--attach-file", "/System/Library/Fonts/Supplemental/Arial.ttf",
            "--chapters", chapters.path
        ], acceptedExitCodes: [0, 1])
        return episode
    }

    static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ALSTests-\(UUID().uuidString)", isDirectory: true)
    }
}
