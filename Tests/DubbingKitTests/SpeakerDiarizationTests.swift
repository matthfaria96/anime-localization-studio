import AVFoundation
import Foundation
import Testing
@testable import DubbingKit
@testable import MediaKit

private let modelsDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("AnimeLocalizationStudioTests/Diarization", isDirectory: true)
private let diarizer = SpeakerDiarization(modelsDirectory: modelsDirectory)
/// Runs when the models are cached, or when ALS_DIARIZATION=1 allows the one-time download.
private let enabled = (diarizer.modelsInstalled || ProcessInfo.processInfo.environment["ALS_DIARIZATION"] == "1")
    && ToolLocator().locate(.ffmpeg) != nil && AVSpeechSynthesisVoice.speechVoices().contains { $0.name == "Eddy" }

@Suite("Speaker diarization (FluidAudio, real models)", .enabled(if: enabled), .serialized)
struct SpeakerDiarizationTests {
    @Test func separatesTwoVoicesAndAssignsLines() async throws {
        let tools = ToolLocator()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ALSDiar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lines = [("Luciana", "Olá, eu sou a primeira pessoa falando neste diálogo de teste, com bastante calma."),
                     ("Eddy", "E eu sou a segunda pessoa, com uma voz bem diferente e grave, respondendo agora."),
                     ("Luciana", "Muito bem, então vamos continuar conversando por mais alguns segundos."),
                     ("Eddy", "Combinado, assim o sistema consegue separar as nossas vozes direitinho.")]
        var parts: [URL] = []
        for (n, line) in lines.enumerated() {
            let url = dir.appendingPathComponent("\(n).wav")
            try await SystemVoiceSynthesizer().synthesize(line.1, voice: line.0, style: nil, speed: 1, to: url)
            parts.append(url)
        }
        // Concatenate with 0.6 s of silence between turns, at 16 kHz mono.
        let list = dir.appendingPathComponent("list.txt")
        let silence = dir.appendingPathComponent("silence.wav")
        try await ProcessRunner.runChecked(try tools.require(.ffmpeg), ["-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i", "anullsrc=r=24000:cl=mono", "-t", "0.6", "-c:a", "pcm_s16le", silence.path])
        try parts.map { "file '\($0.path)'\nfile '\(silence.path)'" }.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        let audio = dir.appendingPathComponent("dialogue.wav")
        try await ProcessRunner.runChecked(try tools.require(.ffmpeg), ["-nostdin", "-v", "error", "-y", "-f", "concat", "-safe", "0", "-i", list.path,
                                                                         "-ar", "16000", "-ac", "1", audio.path])
        // Where each line is in the file.
        var intervals: [(start: Int, end: Int)] = []
        var cursor = 0
        for part in parts {
            let length = try await AudioMixer(tools: tools).duration(of: part)
            intervals.append((cursor, cursor + length))
            cursor += length + 600
        }
        let turns = try await diarizer.diarize(audio, allowModelDownload: true)
        let speakers = Set(turns.map(\.speaker))
        #expect(speakers.count == 2, "\(turns)")
        let assigned = SpeakerDiarization.assign(turns, to: intervals)
        #expect(assigned[0] != nil && assigned[1] != nil)
        #expect(assigned[0] == assigned[2], "\(assigned)")
        #expect(assigned[1] == assigned[3], "\(assigned)")
        #expect(assigned[0] != assigned[1], "\(assigned)")
        #expect(assigned[0] == "Voz 1")
    }

    @Test func refusesToDownloadWithoutPermission() async throws {
        let empty = SpeakerDiarization(modelsDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ALSNoModels-\(UUID().uuidString)"))
        await #expect(throws: SpeakerDiarization.DiarizationError.modelsNotInstalled) {
            try await empty.diarize(URL(fileURLWithPath: "/nonexistent.wav"), allowModelDownload: false)
        }
    }
}

@Suite("Speaker assignment")
struct SpeakerAssignmentTests {
    @Test func picksTheLongestOverlap() {
        let turns = [SpeakerDiarization.Turn(start: 0, end: 1_000, speaker: "Falante 1"),
                     SpeakerDiarization.Turn(start: 1_000, end: 3_000, speaker: "Falante 2")]
        #expect(SpeakerDiarization.assign(turns, to: [(0, 900), (800, 2_500), (5_000, 6_000)]) == ["Falante 1", "Falante 2", nil])
    }
}
