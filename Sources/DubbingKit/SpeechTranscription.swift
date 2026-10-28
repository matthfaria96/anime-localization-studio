import AVFoundation
import Foundation
import Speech
import SubtitleKit

/// On-device transcription with Apple's `SpeechAnalyzer`/`SpeechTranscriber` (macOS 26+), for
/// videos that have no subtitle. Produces timed lines ready to translate. Speakers are not
/// identified (no diarization), and the model for a language may need a one-time download
/// managed by macOS, which the caller must confirm first.
public struct SpeechTranscription: Sendable {
    public struct Line: Sendable, Hashable {
        public var start: Int
        public var end: Int
        public var text: String
    }

    public enum TranscriptionError: Error, LocalizedError, Equatable {
        case unsupportedLanguage(String)
        case modelDownloadRequired(String)
        case nothingRecognized

        public var errorDescription: String? {
            switch self {
            case .unsupportedLanguage(let l): String(localized: "A transcrição da Apple não reconhece o idioma \(l).")
            case .modelDownloadRequired(let l): String(localized: "O macOS precisa baixar o modelo de reconhecimento de fala para \(l).")
            case .nothingRecognized: String(localized: "Nenhuma fala foi reconhecida no áudio.")
            }
        }
    }

    public init() {}

    /// Whether the language works now (`true`), needs the macOS download (`false`), or is not supported (`nil`).
    public static func isReady(language: String) async -> Bool? {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else { return nil }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        return (try? await AssetInventory.assetInstallationRequest(supporting: [transcriber])) == nil
    }

    /// Transcribes a WAV file. With `allowModelDownload`, macOS downloads the language model if needed.
    public func transcribe(_ audio: URL, language: String, allowModelDownload: Bool,
                           progress: (@Sendable (Double) -> Void)? = nil) async throws -> [Line] {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw TranscriptionError.unsupportedLanguage(language)
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            guard allowModelDownload else { throw TranscriptionError.modelDownloadRequired(language) }
            try await request.downloadAndInstall()
        }
        let file = try AVAudioFile(forReading: audio)
        let total = Double(file.length) / file.processingFormat.sampleRate
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> [Line] in
            var lines: [Line] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let start = Int(result.range.start.seconds * 1_000)
                let end = Int(result.range.end.seconds * 1_000)
                lines.append(Line(start: start, end: max(end, start + 300), text: text))
                if total > 0 { progress?(min(1, result.range.end.seconds / total)) }
            }
            return lines
        }
        do {
            if let end = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }
        let lines = try await collector.value
        guard !lines.isEmpty else { throw TranscriptionError.nothingRecognized }
        return lines.flatMap { Self.split($0) }
    }

    /// Long recognized sentences become subtitle-sized lines (≤ ~42 characters × 2, ≤ 7 s),
    /// cut at punctuation or spaces, with time shared in proportion to the text.
    static func split(_ line: Line, maxCharacters: Int = 84, maxDuration: Int = 7_000) -> [Line] {
        guard line.text.count > maxCharacters || line.end - line.start > maxDuration else { return [line] }
        let words = line.text.split(separator: " ").map(String.init)
        guard words.count > 1 else { return [line] }
        var chunks: [String] = []
        var current = ""
        for word in words {
            let candidate = current.isEmpty ? word : current + " " + word
            if candidate.count > maxCharacters / 2 + 12, !current.isEmpty,
               current.last.map({ ",.;:!?…、。！？".contains($0) }) == true || candidate.count > maxCharacters {
                chunks.append(current)
                current = word
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { chunks.append(current) }
        guard chunks.count > 1 else { return [line] }
        let totalCharacters = Double(chunks.reduce(0) { $0 + $1.count })
        var cursor = Double(line.start)
        let span = Double(line.end - line.start)
        return chunks.map { chunk in
            let length = span * Double(chunk.count) / totalCharacters
            defer { cursor += length }
            return Line(start: Int(cursor), end: Int(cursor + length), text: chunk)
        }
    }

    /// An ASS document whose Name (character) field holds each line's speaker.
    public static func document(from lines: [Line], speakers: [String?]) -> SubtitleDocument {
        .ass(ASSDocument.make(events: lines.enumerated().map { n, line in
            (line.start, line.end, line.text, speakers.indices.contains(n) ? speakers[n] ?? "" : "")
        }))
    }

    /// A SubRip document with the lines (two-line wrap left to the player).
    public static func document(from lines: [Line]) -> SubtitleDocument {
        let cues = lines.enumerated().map { SRTCue(number: String($0.offset + 1), start: $0.element.start, end: $0.element.end, text: $0.element.text) }
        return .srt(SRTDocument(preamble: [], cues: cues, traits: TextFileTraits()))
    }
}
