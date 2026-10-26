import Foundation
import Testing
@testable import DubbingKit
@testable import MediaKit
import SubtitleKit

@Suite("On-device transcription (SpeechTranscriber)", .serialized)
struct SpeechTranscriptionTests {
    @Test func transcribesSpeechWithTimes() async throws {
        try #require(await SpeechTranscription.isReady(language: "en-US") == true, "modelo de inglês não instalado neste Mac")
        let tools = ToolLocator()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ALSStt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appendingPathComponent("raw.wav"), wav = dir.appendingPathComponent("speech.wav")
        try await ProcessRunner.runChecked(URL(fileURLWithPath: "/usr/bin/say"), ["-o", raw.path, "--file-format=WAVE", "--data-format=LEI16@16000",
                                                                                 "I won't let you hurt my friends. We have to reach the top floor."])
        try await ProcessRunner.runChecked(try tools.require(.ffmpeg), ["-nostdin", "-v", "error", "-y", "-i", raw.path, "-af", "adelay=1000", wav.path])
        let lines = try await SpeechTranscription().transcribe(wav, language: "en-US", allowModelDownload: false)
        let text = lines.map(\.text).joined(separator: " ").lowercased()
        #expect(text.contains("hurt my") && text.contains("top floor"), "\(text)")
        #expect(lines[0].start >= 800)
        let doc = SpeechTranscription.document(from: lines)
        #expect(doc.format == .srt && doc.count == lines.count)
        #expect((try SubtitleDocument.parse(doc.encoded(), format: .srt)).count == lines.count)
    }

    @Test func longSentencesAreSplitIntoSubtitleLines() {
        let line = SpeechTranscription.Line(start: 0, end: 10_000,
            text: "We have to reach the seventy fifth floor of this castle, no matter what it costs us, because everyone is counting on us today.")
        let parts = SpeechTranscription.split(line)
        #expect(parts.count >= 2)
        #expect(parts.first?.start == 0 && parts.last?.end == 10_000)
        #expect(parts.map(\.text).joined(separator: " ") == line.text)
        #expect(SpeechTranscription.split(.init(start: 0, end: 2_000, text: "Short line.")).count == 1)
    }
}
