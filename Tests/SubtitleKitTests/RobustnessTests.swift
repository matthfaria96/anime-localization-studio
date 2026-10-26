import Foundation
import Testing
@testable import SubtitleKit

@Suite("Robustness")
struct RobustnessTests {
    @Test func mixedLineEndingsRoundTripWhenUntouched() throws {
        let text = "[Script Info]\r\nTitle: x\n\r[Events]\r\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Hi\r\n"
        let data = Data(text.utf8)
        let doc = try SubtitleDocument.parse(data, format: .ass)
        #expect(doc.encoded() == data)
        let srt = Data("1\r\n00:00:01,000 --> 00:00:02,000\nHi\r\r2\n00:00:03,000 --> 00:00:04,000\nBye\n".utf8)
        #expect(try SubtitleDocument.parse(srt, format: .srt).encoded() == srt)
    }

    @Test func editedDocumentsUseTheMajorityLineEnding() throws {
        var doc = try SubtitleDocument.parse(Data("[Events]\r\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\r\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Hi\n".utf8), format: .ass)
        doc.setRawText("Oi", at: 0)
        #expect(doc.serialized().hasSuffix(",,Oi\r\n"))
    }

    @Test func mostlyUTF8FilesAreNotReadAsWindows1252() throws {
        var bytes = [UInt8]("[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Olá, coração ".utf8)
        bytes.append(0xFF)
        bytes += Array("ação\n".utf8)
        let doc = try SubtitleDocument.parse(Data(bytes), format: .ass)
        #expect(doc.rawText(at: 0).hasPrefix("Olá, coração"))
        guard case .ass(let ass) = doc else { Issue.record("not ASS"); return }
        #expect(ass.traits.repairedInvalidBytes)
        #expect(ass.traits.encoding == .utf8)
        // Real Windows-1252 still works.
        let latin = try SubtitleDocument.parse(Data([0x4F, 0x6C, 0xE1, 0x0A]), format: .srt)
        #expect(latin.format == .srt)
    }

    @Test func insertAndRemoveLines() throws {
        var ass = SubtitleDocument.ass(ASSDocument.parse(text: "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.00,0:00:02.00,Sign,,0,0,0,,A\nDialogue: 0,0:00:05.00,0:00:06.00,Default,,0,0,0,,B\n"))
        let new = ass.insertLine(after: 0)
        #expect(ass.count == 3 && new == 1)
        #expect(ass.cues[1].start == 2_000 && ass.cues[1].end == 5_000 && ass.cues[1].style == "Sign" && ass.rawText(at: 1).isEmpty)
        ass.removeLine(at: 1)
        #expect(ass.cues.map(\.rawText) == ["A", "B"])
        var srt = try SubtitleDocument.parse(Data("1\n00:00:01,000 --> 00:00:02,000\nA\n\n2\n00:00:05,000 --> 00:00:06,000\nB\n".utf8), format: .srt)
        srt.insertLine(after: 1)
        #expect(srt.count == 3 && srt.serialized().contains("3\n00:00:06,000 --> 00:00:08,000"))
        srt.removeLine(at: 0)
        #expect(srt.serialized().hasPrefix("1\n00:00:05,000"))
    }
}
