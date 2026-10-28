import CoreGraphics
import Foundation
import Vision

/// Turns bitmap captions into text with Apple's on-device text recognition (Vision).
public struct SubtitleOCR: Sendable {
    public init() {}

    /// Recognized text of one caption, lines top to bottom joined with `\n`.
    public func recognize(_ image: CGImage, language: String) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = [Locale.Language(identifier: language)]
        let observations = try await request.perform(on: image)
        // Vision's coordinates start at the bottom: higher y is higher on screen.
        return observations
            .sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }
            .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// OCR of a whole PGS track into an SRT document. Captions with no readable text are skipped.
    public func document(fromPGS data: Data, language: String, progress: (@Sendable (Double) -> Void)? = nil) async throws -> (SubtitleDocument, skipped: Int) {
        let captions = try PGSDecoder.decode(data)
        var cues: [SRTCue] = []
        var skipped = 0
        for (n, caption) in captions.enumerated() {
            try Task.checkCancellation()
            let text = try await recognize(caption.image, language: language)
            if text.isEmpty { skipped += 1 } else {
                cues.append(SRTCue(number: String(cues.count + 1), start: caption.start, end: max(caption.end, caption.start + 500), text: text))
            }
            progress?(Double(n + 1) / Double(max(1, captions.count)))
        }
        return (.srt(SRTDocument(preamble: [], cues: cues, traits: TextFileTraits())), skipped)
    }
}
