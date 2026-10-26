import Foundation
import SubtitleKit

/// A character of a series and the voice that speaks for them, reused across episodes.
public struct CastMember: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    /// Name as it appears in the subtitle's Actor/Name field or the diarization label.
    public var name: String
    /// VoiceStudio voice profile id, or `nil` while not cast.
    public var voiceID: String?
    /// Style instructions forwarded to the TTS engine (“voz jovem, enérgica”).
    public var style: String
    public var speed: Double
    /// Speaker labels from diarization that belong to this character.
    public var speakerLabels: [String]

    public init(id: UUID = UUID(), name: String, voiceID: String? = nil, style: String = "", speed: Double = 1, speakerLabels: [String] = []) {
        self.id = id
        self.name = name
        self.voiceID = voiceID
        self.style = style
        self.speed = speed
        self.speakerLabels = speakerLabels
    }
}

public struct VoiceCast: Sendable, Hashable, Codable {
    public var members: [CastMember]

    public init(members: [CastMember] = []) { self.members = members }

    public func member(for speaker: String) -> CastMember? {
        members.first { $0.name.caseInsensitiveCompare(speaker) == .orderedSame || $0.speakerLabels.contains(speaker) }
    }

    /// Adds every speaker of the document that is not cast yet.
    public mutating func addMissing(from speakers: [String]) {
        for speaker in speakers where member(for: speaker) == nil { members.append(CastMember(name: speaker)) }
    }
}

/// One line to be spoken: where it must fit and who says it.
public struct DubSegment: Sendable, Hashable, Codable, Identifiable {
    public var id: Int
    public var start: Int
    public var end: Int
    public var speaker: String
    public var text: String

    public var slot: Int { max(0, end - start) }
    /// Rough speaking rate check: Brazilian Portuguese dubbing runs near 15 characters per second.
    public var isLikelyTooLong: Bool { slot > 0 && Double(text.count) / (Double(slot) / 1_000) > 18 }
}

public enum DubbingPlan {
    /// Dialogue lines of a translated subtitle in time order, skipping signs (positioned lines
    /// and sign/song styles), karaoke, comments and drawings.
    public static func segments(from document: SubtitleDocument, signStyles: Set<String> = ["sign", "signs", "op", "ed", "song"]) -> [DubSegment] {
        let cues = document.cues.filter { cue in
            !cue.isComment && !cue.features.hasDrawing && !cue.features.hasKaraoke
                && !signStyles.contains { cue.style.lowercased().hasPrefix($0) }
                && !cue.features.hasPositioning
                && cue.plainText.contains { $0.isLetter || $0.isNumber }  // "♪ ♪" has nothing to say
        }.sorted { $0.start < $1.start }
        return cues.map { cue in
            DubSegment(id: cue.id, start: cue.start, end: cue.end, speaker: cue.actor.isEmpty ? "Desconhecido" : cue.actor,
                       text: cue.plainText.replacingOccurrences(of: "\n", with: " "))
        }
    }

    public static func speakers(in segments: [DubSegment]) -> [String] {
        var seen: [String] = []
        for segment in segments where !seen.contains(segment.speaker) { seen.append(segment.speaker) }
        return seen
    }
}
