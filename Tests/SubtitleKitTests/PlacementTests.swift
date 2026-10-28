import Foundation
import Testing
@testable import SubtitleKit

@Suite("Where a line sits on screen")
struct PlacementTests {
    private func document(_ events: String) throws -> ASSDocument {
        ASSDocument.parse(text: """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 1920
        PlayResY: 1080

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Arial,60,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,1,2,40,80,50,1
        Style: Top,Arial,60,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,1,8,40,40,30,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        \(events)
        """)
    }

    @Test func settingAPositionReplacesOrAddsOnlyThePosTag() {
        #expect(ASSText.settingPosition((640, 360), in: "Hello") == #"{\pos(640,360)}Hello"#)
        #expect(ASSText.settingPosition((640, 360), in: #"{\an8\fad(200,0)}Hello"#) == #"{\an8\fad(200,0)\pos(640,360)}Hello"#)
        #expect(ASSText.settingPosition((10.5, 20), in: #"{\pos(1,2)\i1}Hi{\i0}"#) == #"{\pos(10.5,20)\i1}Hi{\i0}"#)
        #expect(ASSText.settingPosition(nil, in: #"{\pos(1,2)}Hi"#) == "Hi")
        #expect(ASSText.settingPosition(nil, in: #"{\an8\pos(1,2)}Hi"#) == #"{\an8}Hi"#)
        // A comment block in front is not an override block: a new one is added.
        #expect(ASSText.settingPosition((1, 2), in: "{TL note}Hi") == #"{\pos(1,2)}{TL note}Hi"#)
    }

    @Test func movingLinesAreRecognized() {
        #expect(ASSText.hasMovement(#"{\move(0,0,100,100)}Hi"#))
        #expect(!ASSText.hasMovement(#"{\pos(1,2)}Hi"#))
    }

    @Test func anchorFollowsStyleMarginsAndAlignment() throws {
        let doc = try document("""
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Bottom center
        Dialogue: 0,0:00:01.00,0:00:02.00,Top,,0,0,0,,Top center
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\\an7}Top left
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\\an5}Middle
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,100,0,200,,{\\an1}Line margins
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\\pos(300,400)}Exact
        """)
        #expect(doc.anchor(ofEvent: 0) == ASSPoint(x: (40 + 1920 - 80) / 2, y: 1080 - 50))
        #expect(doc.anchor(ofEvent: 1) == ASSPoint(x: 960, y: 30))
        #expect(doc.anchor(ofEvent: 2) == ASSPoint(x: 40, y: 50))
        #expect(doc.anchor(ofEvent: 3) == ASSPoint(x: 940, y: 540))
        #expect(doc.anchor(ofEvent: 4) == ASSPoint(x: 100, y: 1080 - 200))
        #expect(doc.anchor(ofEvent: 5) == ASSPoint(x: 300, y: 400))
    }

    @Test func turningTheStylePlacementIntoAPointKeepsTheLineWhereItWas() throws {
        var doc = try document("Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Hello")
        let anchor = doc.anchor(ofEvent: 0)
        doc.updateEvent(at: 0) { $0.text = ASSText.settingPosition((anchor.x, anchor.y), in: $0.text) }
        // With \pos the alignment point of the line is that point, whatever the margins.
        #expect(doc.event(at: 0).text == #"{\pos(940,1030)}Hello"#)
        #expect(doc.anchor(ofEvent: 0) == anchor)
    }
}
