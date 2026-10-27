import Foundation
import Testing
@testable import SubtitleKit

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite("ASS/SSA document")
struct ASSDocumentTests {
    @Test func untouchedDocumentRoundTripsByteForByte() throws {
        let data = try fixture("fansub-crlf-bom.ass")
        let doc = try ASSDocument.parse(data)
        #expect(doc.traits.hasBOM)
        #expect(doc.traits.newline == "\r\n")
        #expect(doc.encoded() == data)
    }

    @Test func parsesStylesEventsAndScriptInfo() throws {
        let doc = try ASSDocument.parse(try fixture("fansub-crlf-bom.ass"))
        #expect(doc.styleCount == 4)
        #expect(doc.eventCount == 11)
        #expect(doc.playResolution.width == 1920)
        #expect(doc.playResolution.height == 1080)
        #expect(doc.scriptInfo("Title") == "Fansub Test Episode 01")
        #expect(doc.embeddedFontNames == ["OpenSans-Semibold_0.ttf"])
        let first = doc.event(at: 1)
        #expect(first.actor == "Kirito")
        #expect(first.start == 1_500)
        #expect(first.end == 4_200)
        #expect(first.layer == 10)
        // Commas inside Text stay in Text.
        #expect(doc.event(at: 3).text == "We have to reach the 75th floor,\\Nno matter what it costs.")
        #expect(doc.event(at: 0).isComment)
        #expect(doc.style(named: "sign")?["Alignment"] == "8")
    }

    @Test func editingTextChangesOnlyThatField() throws {
        let data = try fixture("fansub-crlf-bom.ass")
        var doc = try ASSDocument.parse(data)
        doc.updateEvent(at: 3) { $0.text = "Precisamos chegar ao 75º andar,\\Ncusto o que custar." }
        let output = doc.serialized()
        // The raw margins "0000" survive, and only the one line differs from the input.
        #expect(output.contains("Dialogue: 10,0:00:08.00,0:00:11.00,Default,Kirito,0000,0000,0000,,Precisamos chegar ao 75º andar,\\Ncusto o que custar."))
        let before = String(decoding: data.dropFirst(3), as: UTF8.self).components(separatedBy: "\r\n")
        let after = output.components(separatedBy: "\r\n")
        #expect(before.count == after.count)
        #expect(zip(before, after).filter { $0 != $1 }.count == 1)
    }

    @Test func untouchedTimingKeepsItsSpelling() {
        let text = "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.5,0:00:02.00,Default,,0,0,0,,Hi\n"
        var doc = ASSDocument.parse(text: text)
        doc.updateEvent(at: 0) { $0.text = "Oi" }
        #expect(doc.serialized().contains("0:00:01.5,0:00:02.00"))
    }

    @Test func ssaUsesItsOwnDefaults() {
        let text = "[Script Info]\nScriptType: v4.00\n\n[V4 Styles]\nFormat: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, TertiaryColour, BackColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, AlphaLevel, Encoding\nStyle: Default,Arial,20,16777215,65535,65535,-2147483640,-1,0,1,3,0,2,30,30,30,0,0\n\n[Events]\nFormat: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: Marked=0,0:00:01.00,0:00:02.00,Default,,0000,0000,0000,,Hello, world\n"
        let doc = ASSDocument.parse(text: text)
        #expect(doc.isSSA)
        #expect(doc.event(at: 0).text == "Hello, world")
        #expect(doc.serialized() == text)
    }

    @Test func duplicateAndRemoveKeepIndicesConsistent() throws {
        var doc = try ASSDocument.parse(try fixture("fansub-crlf-bom.ass"))
        let copy = doc.duplicateEvent(at: 1)
        #expect(doc.eventCount == 12)
        #expect(doc.event(at: copy).text == doc.event(at: 1).text)
        doc.removeEvent(at: copy)
        #expect(doc.eventCount == 11)
        #expect(doc.encoded() == (try fixture("fansub-crlf-bom.ass")))
    }

    @Test func linesWithoutFormatUseTheDefaultLayout() {
        let doc = ASSDocument.parse(text: "[Events]\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Text, with comma\n")
        #expect(doc.event(at: 0).text == "Text, with comma")
    }
}

@Suite("Subtitle times")
struct SubtitleTimeTests {
    @Test func parsesAndFormats() {
        #expect(SubtitleTime.parseASS("0:00:01.50") == 1_500)
        #expect(SubtitleTime.parseASS("1:02:03.04") == 3_723_040)
        #expect(SubtitleTime.parseASS("0:00:01.5") == 1_500)
        #expect(SubtitleTime.parseSRT("00:00:04,300") == 4_300)
        #expect(SubtitleTime.formatASS(3_723_046) == "1:02:03.05")
        #expect(SubtitleTime.formatSRT(3_723_046) == "01:02:03,046")
        #expect(SubtitleTime.parseFlexible("1:05.20") == 65_200)
        #expect(SubtitleTime.parseFlexible("abc") == nil)
        #expect(SubtitleTime.parseASS("0:61:x") == nil)
    }
}

@Suite("Style editing and fonts")
struct StyleEditingTests {
    private let script = """
    [Script Info]
    ScriptType: v4.00+

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Open Sans Semibold,60,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,3,1,2,40,40,40,1
    Style: Sign,@Arial,50,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,3,1,8,40,40,40,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Hello
    Dialogue: 0,0:00:03.00,0:00:04.00,Sign,,0,0,0,,{\\fnTrebuchet MS\\b1}Town
    Dialogue: 0,0:00:05.00,0:00:06.00,Default,,0,0,0,,Bye

    """

    @Test func duplicateRenameAndRemoveKeepEventsConsistent() throws {
        var doc = ASSDocument.parse(text: script)
        let added = doc.duplicateStyle(at: 0, named: "Default")
        let index = try #require(added)
        #expect(doc.styleNames == ["Default", "Default 2", "Sign"])
        #expect(doc.styles[index]["Fontname"] == "Open Sans Semibold")

        doc.renameStyle(at: 0, to: "Fala")
        #expect(doc.styleNames.first == "Fala")
        #expect(doc.eventCount(usingStyle: "Fala") == 2 && doc.eventCount(usingStyle: "Default") == 0)

        doc.removeStyle(at: 2, movingEventsTo: "Fala")
        #expect(doc.styleNames == ["Fala", "Default 2"])
        #expect(doc.eventCount(usingStyle: "Fala") == 3)
        #expect(doc.events[1].text == "{\\fnTrebuchet MS\\b1}Town", "only the style field changes")
    }

    @Test func untouchedLinesKeepTheirText() {
        var doc = ASSDocument.parse(text: script)
        doc.duplicateStyle(at: 1, named: "Sign")
        #expect(doc.serialized().contains("Style: Default,Open Sans Semibold,60,&H00FFFFFF"))
        #expect(doc.serialized().contains("Dialogue: 0,0:00:05.00,0:00:06.00,Default,,0,0,0,,Bye"))
    }

    @Test func listsStyleAndInlineFonts() {
        #expect(ASSDocument.parse(text: script).usedFonts == ["Arial", "Open Sans Semibold", "Trebuchet MS"])
    }
}
