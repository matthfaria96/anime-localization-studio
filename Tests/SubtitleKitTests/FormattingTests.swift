import Foundation
import Testing
@testable import SubtitleKit

@Suite("Formatting a line without typing tags")
struct FormattingTests {
    private func range(of part: String, in text: String) -> Range<String.Index> { text.range(of: part)! }

    @Test func wrapsTheSelectionAndUnwrapsItAgain() {
        let text = "Realmente não faz sentido se você me matar!"
        let italic = ASSFormatting.toggle(.italic, in: text, range: range(of: "não", in: text))
        #expect(italic == #"Realmente {\i1}não{\i0} faz sentido se você me matar!"#)
        let back = ASSFormatting.toggle(.italic, in: italic, range: range(of: "não", in: italic))
        #expect(back == text)
    }

    @Test func withoutSelectionTheWholeLineChangesAndPositionTagsStay() {
        let bold = ASSFormatting.toggle(.bold, in: #"{\an8}Hello"#, range: nil)
        #expect(bold == #"{\an8\b1}Hello"#)
        #expect(ASSFormatting.toggle(.bold, in: bold, range: nil) == #"{\an8}Hello"#)
        #expect(ASSFormatting.toggle(.underline, in: "Hi", range: nil) == #"{\u1}Hi"#)
    }

    @Test func aSelectionNeverCutsATagInHalf() {
        let text = #"A {\i1}b{\i0} c"#
        // From inside “{\i1” to the end: the start moves out of the tag block.
        let start = text.index(text.startIndex, offsetBy: 4)
        let result = ASSFormatting.toggle(.bold, in: text, range: start..<text.endIndex)
        #expect(result == #"A {\i1}{\b1}b{\i0} c{\b0}"#)
    }

    @Test func colorAndSizeComeBackToTheStyleAfterTheSelection() {
        let text = "Danger ahead"
        let red = ASSFormatting.color(ASSColor(red: 1, green: 0, blue: 0), restore: ASSColor(red: 1, green: 1, blue: 1),
                                      in: text, range: range(of: "Danger", in: text))
        #expect(red == #"{\1c&H0000FF&}Danger{\1c&HFFFFFF&} ahead"#)
        let big = ASSFormatting.size(72, restore: 48, in: text, range: nil)
        #expect(big == #"{\fs72}Danger ahead"#)
    }

    @Test func clearingTakesOutLookButKeepsPositionAndTiming() {
        let text = #"{\an8\pos(10,20)\fad(200,0)\i1\c&H00FFFF&\fs60}Hi {\b1}there{\b0}"#
        #expect(ASSFormatting.clear(in: text, range: nil) == #"{\an8\pos(10,20)\fad(200,0)}Hi there"#)
        // Karaoke goes too, for the whole line or a selected stretch.
        #expect(ASSFormatting.clear(in: #"{\an8\kf60}sa{\kf60}ka{\k30}ra"#, range: nil) == #"{\an8}sakara"#)
        let karaoke = #"{\kf60}sa{\kf60}ka{\k30}ra"#
        #expect(ASSFormatting.clear(in: karaoke, range: karaoke.range(of: "ka{\\k30}ra")!) == #"{\kf60}sa{\kf60}kara"#)
    }

    @Test func srtUsesItsOwnMarkup() {
        let text = "Não vou deixar"
        #expect(ASSFormatting.toggle(.italic, in: text, range: range(of: "deixar", in: text), html: true) == "Não vou <i>deixar</i>")
        #expect(ASSFormatting.toggle(.italic, in: "<i>Oi</i>", range: nil, html: true) == "Oi")
        #expect(ASSFormatting.color(ASSColor(red: 1, green: 1, blue: 0), restore: nil, in: "Oi", range: nil, html: true)
                == ##"<font color="#FFFF00">Oi</font>"##)
        #expect(ASSFormatting.clear(in: ##"<b><font color="#FF0000">Oi</font></b>"##, range: nil, html: true) == "Oi")
    }

    @Test func runsDescribeHowTheLineLooks() {
        let runs = ASSFormatting.runs(#"{\an8}Realmente {\i1}não{\i0} faz {\b1\c&H0000FF&}sentido"#)
        #expect(runs.map(\.text) == ["Realmente ", "não", " faz ", "sentido"])
        #expect(runs.map(\.italic) == [false, true, false, false])
        #expect(runs[3].bold && runs[3].color == ASSColor(red: 1, green: 0, blue: 0))
        let html = ASSFormatting.runs("Oi <i>você</i>", html: true)
        #expect(html.map(\.text) == ["Oi ", "você"] && html[1].italic)
    }
}
