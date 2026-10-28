import Foundation
import Testing
@testable import SubtitleKit

@Suite("Karaoke")
struct KaraokeTests {
    @Test func readsAndWritesSyllablesKeepingOtherTags() throws {
        let raw = #"{\an8\k20}sa{\k15}ka{\kf30\1c&H0000FF&}ra{\k25}u"#
        let line = try #require(KaraokeLine.parse(raw))
        #expect(line.syllables.map(\.text) == ["sa", "ka", "ra", "u"])
        #expect(line.syllables.map(\.centiseconds) == [20, 15, 30, 25])
        #expect(line.totalMilliseconds == 900)
        #expect(line.text == raw.replacingOccurrences(of: #"{\an8\k20}"#, with: #"{\an8\k20}"#))
        #expect(KaraokeLine.parse("No karaoke here") == nil)
    }

    @Test func romajiSplitsIntoSyllables() {
        #expect(KaraokeLine.syllables(of: "sakarau yatsura wa oshioki yo!", by: .syllable)
                == ["sa", "ka", "ra", "u ", "ya", "tsu", "ra ", "wa ", "o", "shi", "o", "ki ", "yo!"])
        #expect(KaraokeLine.syllables(of: "kitto shinjite", by: .syllable) == ["ki", "t", "to ", "shi", "n", "ji", "te"])
        #expect(KaraokeLine.syllables(of: "君の名は", by: .syllable) == ["君", "の", "名", "は"])
        #expect(KaraokeLine.syllables(of: "sakarau yatsura", by: .word) == ["sakarau ", "yatsura"])
    }

    @Test func makingKaraokeSpreadsTheLineDurationByLetters() throws {
        let line = KaraokeLine.make(from: #"{\an8}sakarau"#, duration: 1_000, by: .syllable, kind: .fill)
        #expect(line.prefix == #"{\an8}"#)
        #expect(line.syllables.map(\.text) == ["sa", "ka", "ra", "u"])
        #expect(line.syllables.reduce(0) { $0 + $1.centiseconds } == 100)
        #expect(line.text.hasPrefix(#"{\an8}{\kf"#))
        let parsed = try #require(KaraokeLine.parse(line.text))
        #expect(parsed.syllables.map(\.text) == line.syllables.map(\.text))
    }

    @Test func timesMarkedWhilePlayingBecomeDurations() {
        var line = KaraokeLine.make(from: "sa ka ra", duration: 900, by: .word, kind: .color)
        // Marks (ms from the line start) where each syllable after the first begins; the last ends with the line.
        line.setStarts([0, 250, 700], lineDuration: 900)
        #expect(line.syllables.map(\.centiseconds) == [25, 45, 20])
    }

    @Test func emptyLinesCopyTheTimingOfAnotherSubtitle() {
        let reference = SubtitleDocument.ass(ASSDocument.parse(text: """
        [Script Info]
        PlayResX: 1280
        PlayResY: 720

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Sign,Arial,40,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,8,10,10,10,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,Kirito,0,0,0,,{\\an8}Good {\\i1}morning{\\i0}
        Dialogue: 0,0:00:03.00,0:00:04.00,Sign,,0,0,0,,{\\pos(10,20)}FLOOR 75
        """))
        let blank = SubtitleDocument.ass(ASSDocument.make(events: [(start: 0, end: 2_000, text: "", actor: "")], playResX: 1920, playResY: 1080))
        #expect(blank.isBlank && !reference.isBlank)
        #expect(blank.differsInTiming(from: reference))
        let copy = reference.timingCopy()
        #expect(copy.isBlank)
        #expect(copy.cues.map(\.start) == [1_000, 3_000] && copy.cues.map(\.style) == ["Default", "Sign"])
        #expect(copy.rawText(at: 0) == #"{\an8}"# && copy.rawText(at: 1) == #"{\pos(10,20)}"#, "the place on screen is kept")
        #expect(copy.cues[0].actor == "Kirito")
        #expect(!copy.differsInTiming(from: reference))
    }
}
