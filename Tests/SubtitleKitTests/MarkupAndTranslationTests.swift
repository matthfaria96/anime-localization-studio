import Foundation
import Testing
@testable import SubtitleKit

@Suite("Override tags")
struct ASSTextTests {
    @Test func tokensRebuildTheInput() {
        let text = #"{\an8\pos(960,120)}Hello {\i1}there{\i0},\Nfriend\h!"#
        #expect(ASSText.tokenize(text).map(\.source).joined() == text)
    }

    @Test func plainTextDropsTagsAndDrawings() {
        #expect(ASSText.plainText(#"{\i1}Hi{\i0}\Nthere"#) == "Hi\nthere")
        #expect(ASSText.plainText(#"{\p1}m 0 0 l 10 0{\p0}Label"#) == "Label")
        #expect(ASSText.plainText("<i>Hi</i>", htmlMarkup: true) == "Hi")
    }

    @Test func detectsFeatures() {
        let karaoke = ASSText.features(of: #"{\k32}Ki{\k25}ra"#)
        #expect(karaoke.hasKaraoke)
        let drawing = ASSText.features(of: #"{\an7\pos(1,2)\p1}m 0 0 l 1 1{\p0}"#)
        #expect(drawing.hasDrawing && drawing.hasPositioning)
        #expect(!ASSText.features(of: #"{\pos(1,2)}Text"#).hasDrawing)
        #expect(ASSText.features(of: #"{\t(0,500,\fscx120)}X"#).hasAnimation)
        #expect(ASSText.features(of: "{TL note}Hi").hasCommentBlocks)
        #expect(ASSText.tagNames(in: #"{\fnArial\fs40\fscx120\bord2\b1\1c&HFFFFFF&}"#) == ["fn", "fs", "fscx", "bord", "b", "1c"])
    }

    @Test func readsAlignmentAndPosition() {
        #expect(ASSText.alignmentOverride(in: #"{\an8}X"#) == 8)
        let pos = ASSText.positionOverride(in: #"{\pos(960.5, 120)}X"#)
        #expect(pos?.x == 960.5 && pos?.y == 120)
    }
}

@Suite("Translatable text")
struct TranslatableTextTests {
    @Test func leadingTagsNeverReachTheTranslator() throws {
        let t = try #require(TranslatableText(rawText: #"{\an8\pos(960,120)\fad(200,200)}The Town of Beginnings"#))
        #expect(t.body == "The Town of Beginnings")
        #expect(t.placeholders.isEmpty)
        #expect(try t.rebuild(translation: "A Cidade do Início") == #"{\an8\pos(960,120)\fad(200,200)}A Cidade do Início"#)
    }

    @Test func innerTagsBecomePlaceholders() throws {
        let t = try #require(TranslatableText(rawText: #"Wait... {\i1}where{\i0} are you going?"#))
        #expect(t.body == "Wait... ⟦1⟧where⟦2⟧ are you going?")
        #expect(try t.rebuild(translation: "Espera... ⟦1⟧aonde⟦2⟧ você vai?") == #"Espera... {\i1}aonde{\i0} você vai?"#)
    }

    @Test func missingPlaceholderIsRejected() throws {
        let t = try #require(TranslatableText(rawText: #"Wait {\i1}where{\i0} now"#))
        #expect(throws: TranslatableText.RebuildError.self) { try t.rebuild(translation: "Espera aonde agora") }
        #expect(throws: TranslatableText.RebuildError.self) { try t.rebuild(translation: "⟦1⟧⟦1⟧⟦2⟧") }
    }

    @Test func segmentFallbackKeepsTags() throws {
        let t = try #require(TranslatableText(rawText: #"Wait {\i1}where{\i0} now"#))
        #expect(t.segments == ["Wait ", "where", " now"])
        #expect(try t.rebuild(segments: ["Espera", "aonde", "agora"]) == #"Espera {\i1}aonde{\i0} agora"#)
    }

    @Test func lineBreaksAreRebalanced() throws {
        let t = try #require(TranslatableText(rawText: #"We have to reach the 75th floor,\Nno matter what it costs."#))
        #expect(t.body == "We have to reach the 75th floor, no matter what it costs.")
        let rebuilt = try t.rebuild(translation: "Precisamos chegar ao 75º andar, custe o que custar.")
        #expect(rebuilt.components(separatedBy: "\\N").count == 2)
        // A break the translator chose is kept.
        #expect(try t.rebuild(translation: "Precisamos chegar,\ncuste o que custar.") == #"Precisamos chegar,\Ncuste o que custar."#)
    }

    @Test func translatorTextCannotCreateTags() throws {
        let t = try #require(TranslatableText(rawText: "Hello"))
        #expect(try t.rebuild(translation: #"Olá {\an8} \N"#) == #"Olá (＼an8)"#)
    }

    @Test func hardSpacesSurvive() throws {
        let t = try #require(TranslatableText(rawText: #"Hey,\hguys!"#))
        #expect(try t.rebuild(translation: "Ei,\u{00A0}pessoal!") == #"Ei,\hpessoal!"#)
    }

    @Test func linesWithoutWordsAreSkipped() {
        #expect(TranslatableText(rawText: #"{\an8}♪ ♪"#) == nil)
        #expect(TranslatableText(rawText: #"{\p1}m 0 0{\p0}"#) == nil)
    }

    @Test func srtMarkup() throws {
        let t = try #require(TranslatableText(rawText: "Wait, Kirito-kun...\n<i>where</i> are you going?", htmlMarkup: true))
        #expect(t.lineBreakCount == 1)
        #expect(t.body == "Wait, Kirito-kun... ⟦1⟧where⟦2⟧ are you going?")
        let rebuilt = try t.rebuild(translation: "Espera, Kirito-kun... ⟦1⟧aonde⟦2⟧ você vai?")
        #expect(rebuilt.contains("<i>aonde</i>"))
        #expect(rebuilt.contains("\n"))
    }
}

@Suite("Unified document")
struct SubtitleDocumentTests {
    @Test func srtRoundTripsAndEdits() throws {
        let data = try fixture("simple.srt")
        var doc = try SubtitleDocument.parse(data, format: .srt)
        #expect(doc.count == 3)
        #expect(doc.encoded() == data)
        #expect(doc.cues[1].start == 4_300)
        doc.setRawText("Espera...", at: 1)
        let out = doc.serialized()
        #expect(out.contains("00:00:04,300 --> 00:00:07,800 X1:100 X2:200 Y1:50 Y2:80\nEspera...\n\n3"))
    }

    @Test func loneCarriageReturnsNeverSplitAnEventLine() throws {
        let t = try #require(TranslatableText(rawText: #"{\an8}Hello there"#))
        var doc = try SubtitleDocument.parse(try fixture("fansub-crlf-bom.ass"), format: .ass)
        doc.setRawText(try t.rebuild(translation: "Olá\rtudo bem"), at: 1)
        doc.setActor("Kiri\rto", at: 1)
        let reparsed = try SubtitleDocument.parse(doc.encoded(), format: .ass)
        #expect(reparsed.count == doc.count)
        #expect(reparsed.rawText(at: 1) == #"{\an8}Olá\Ntudo bem"#, "\(reparsed.rawText(at: 1).debugDescription) actor \(reparsed.cues[1].actor.debugDescription)")
        #expect(reparsed.cues[1].actor == "Kiri to")
    }

    @Test func skipReasons() throws {
        let doc = try SubtitleDocument.parse(try fixture("fansub-crlf-bom.ass"), format: .ass)
        #expect(doc.skipReason(at: 0) == .comment)
        #expect(doc.skipReason(at: 1) == nil)
        #expect(doc.skipReason(at: 5) == .drawing)
        #expect(doc.skipReason(at: 6) == .karaoke)
        #expect(doc.skipReason(at: 6, translateKaraoke: true) == nil)
        #expect(doc.skipReason(at: 9) == .noText)
    }

    @Test func replaceNeverTouchesTags() throws {
        var doc = try SubtitleDocument.parse(try fixture("fansub-crlf-bom.ass"), format: .ass)
        let changed = doc.replace("i", with: "I", caseSensitive: true, indices: [2])
        #expect(changed == 1)
        #expect(doc.rawText(at: 2).contains(#"{\i1}"#))
        #expect(doc.find("kirito-kun") == [2])
    }

    @Test func shiftMovesTiming() throws {
        var doc = try SubtitleDocument.parse(try fixture("simple.srt"), format: .srt)
        doc.shift(by: 250)
        #expect(doc.cues[0].start == 1_750)
        #expect(doc.cues[2].end == 11_250)
    }

    @Test func structureCheckFlagsNonTextChanges() throws {
        let source = try SubtitleDocument.parse(try fixture("fansub-crlf-bom.ass"), format: .ass)
        var translated = source
        translated.setRawText("Eu não vou deixar você machucar meus amigos!", at: 1)
        let ok = StructureCheck.compare(source: source, translated: translated)
        #expect(ok.isValid)
        #expect(ok.changedTextLines == 1)
        translated.setTiming(start: 2_000, end: 4_200, at: 1)
        #expect(!StructureCheck.compare(source: source, translated: translated).isValid)
    }
}

@Suite("Reference beside the edited subtitle")
struct ReferenceTests {
    @Test func linesAreMatchedByTimeAndUnmatchedOnesAreLeftOut() throws {
        let edited = try SubtitleDocument.parse(Data("""
        1
        00:00:01,000 --> 00:00:03,000
        Eu não vou deixar

        2
        00:00:04,000 --> 00:00:05,000
        Espera!

        3
        00:00:10,000 --> 00:00:11,000
        (silêncio)

        """.utf8), format: .srt)
        let english = try SubtitleDocument.parse(Data("""
        1
        00:00:01,100 --> 00:00:02,000
        I won't let you

        2
        00:00:04,100 --> 00:00:05,200
        <i>Wait!</i>

        """.utf8), format: .srt)
        let lines = TranslationAlignment.reference(english, for: edited)
        #expect(lines[0] == "I won't let you")
        #expect(lines[1] == "Wait!")
        #expect(lines[2] == nil)
    }
}

@Suite("Characters in SubRip")
struct SRTSpeakerTests {
    @Test func charactersStayOutOfTheFile() throws {
        let data = Data("1\n00:00:01,000 --> 00:00:02,000\nOi\n\n2\n00:00:03,000 --> 00:00:04,000\nTchau\n\n".utf8)
        var doc = try SubtitleDocument.parse(data, format: .srt)
        doc.setActor("Kirito", at: 1)
        #expect(doc.cues[1].actor == "Kirito")
        #expect(doc.encoded() == data, "the file is byte for byte the same")
        #expect(doc.sideSpeakers == [1: "Kirito"])
        let reloaded = try SubtitleDocument.parse(data, format: .srt).withSideSpeakers(doc.sideSpeakers)
        #expect(reloaded.cues[1].actor == "Kirito")
        doc.insertLine(after: 0)
        #expect(doc.cues[2].actor == "Kirito", "the name moves with its line")
    }
}

@Suite("Line position")
struct LinePositionTests {
    @Test func setsReplacesAndRemovesTheAlignmentTag() {
        #expect(ASSText.settingAlignment(8, in: "Hello") == "{\\an8}Hello")
        #expect(ASSText.settingAlignment(8, in: "{\\i1}Hello") == "{\\an8\\i1}Hello")
        #expect(ASSText.settingAlignment(7, in: "{\\an8\\i1}Hello") == "{\\an7\\i1}Hello")
        #expect(ASSText.settingAlignment(nil, in: "{\\an8}Hello") == "Hello")
        #expect(ASSText.settingAlignment(nil, in: "{\\an8\\b1}Hi {\\i1}there") == "{\\b1}Hi {\\i1}there")
        #expect(ASSText.alignmentOverride(in: ASSText.settingAlignment(3, in: "{\\pos(10,20)}Sign")) == 3)
    }
}
