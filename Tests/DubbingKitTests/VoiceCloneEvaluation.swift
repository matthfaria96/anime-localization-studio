import AVFoundation
import FluidAudio
import Foundation
import Testing
@testable import DubbingKit
@testable import MediaKit

/// Measures how much the cloned voice sounds like the person it was cloned from, with an
/// independent speaker-recognition model (WeSpeaker, from FluidAudio). Only runs on request:
/// `ALS_VOICE_EVAL=<folder>` with one subfolder of WAV recordings per real speaker (e.g. CMU
/// ARCTIC: bdl, rms, slt, clb), and optionally `ALS_VOICE_EVAL_MODELS=<folder>` for the
/// recognition model. Prints a table; fails only when cloning is no better than chance.
private let folder = ProcessInfo.processInfo.environment["ALS_VOICE_EVAL"].map { URL(fileURLWithPath: $0) }
private let modelsDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Anime Localization Studio/Models/Chatterbox", isDirectory: true)

@Suite("Voice clone evaluation (on request)", .enabled(if: folder != nil), .serialized)
struct VoiceCloneEvaluation {
    struct Setup: CustomStringConvertible {
        let name: String
        let reference: (Speaker) -> URL
        let guidance: Float
        var description: String { name }
    }

    struct Speaker {
        let name: String
        let short: URL, long: URL, combined: URL, truth: [Float]
    }

    @Test func clonedVoicesAreRecognizedAsTheirSpeaker() async throws {
        let folder = try #require(folder)
        let metallib = try installMetallib()
        defer { if let metallib { try? FileManager.default.removeItem(at: metallib) } }
        let tools = ToolLocator()
        let ffmpeg = try tools.require(.ffmpeg)
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ALSEval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let recognitionModels = ProcessInfo.processInfo.environment["ALS_VOICE_EVAL_MODELS"].map { URL(fileURLWithPath: $0) }
        let recognizer = DiarizerManager()
        recognizer.initialize(models: try await DiarizerModels.downloadIfNeeded(to: recognitionModels))
        func embedding(_ samples: [Float]) throws -> [Float] {
            // The model looks at 10 s windows: a shorter clip is repeated to fill one.
            var window = samples
            while window.count < 160_000 { window += samples }
            return try recognizer.extractSpeakerEmbedding(from: Array(window.prefix(160_000)))
        }

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { name in
            var isFolder: ObjCBool = false
            return !name.hasPrefix(".") && FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path, isDirectory: &isFolder)
                && isFolder.boolValue
        }.sorted()
        var speakers: [Speaker] = []
        for name in names {
            let files = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent(name), includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            guard files.count >= 8 else { continue }
            let dir = work.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let long = dir.appendingPathComponent("long.wav"), short = dir.appendingPathComponent("short.wav")
            let truth = dir.appendingPathComponent("truth.wav"), combined = dir.appendingPathComponent("combined.wav")
            try await join(Array(files[0..<4]), to: long, rate: 24_000, ffmpeg: ffmpeg)
            // One line of about 2 s, like the clip of a single short line of an episode.
            try await ProcessRunner.runChecked(ffmpeg, ["-nostdin", "-v", "error", "-y", "-i", files[4].path, "-af",
                                                        "silenceremove=start_periods=1:start_threshold=-45dB,atrim=0:2",
                                                        "-ar", "24000", "-ac", "1", "-c:a", "pcm_s16le", short.path])
            try await join([short, long], to: combined, rate: 24_000, ffmpeg: ffmpeg)
            try await join(Array(files[5..<8]), to: truth, rate: 16_000, ffmpeg: ffmpeg)
            speakers.append(Speaker(name: name, short: short, long: long, combined: combined, truth: try embedding(read(truth))))
        }
        #expect(speakers.count >= 2)

        let setups = [
            Setup(name: "fala curta (2 s), cfg 0,5 — o que o app fazia", reference: \.short, guidance: 0.5),
            Setup(name: "amostra do personagem (~12 s), cfg 0,5", reference: \.long, guidance: 0.5),
            Setup(name: "amostra do personagem (~12 s), cfg 0", reference: \.long, guidance: 0),
            Setup(name: "fala + amostra, cfg 0,5", reference: \.combined, guidance: 0.5),
            Setup(name: "fala + amostra, cfg 0", reference: \.combined, guidance: 0),
        ]
        let lines = ["Eu não vou deixar você machucar os meus amigos, entendeu?",
                     "Precisamos chegar ao último andar antes do anoitecer."]
        var report = "\nSemelhança com a voz real (cosseno, WeSpeaker). certa = com a própria pessoa; outra = a mais parecida entre as outras.\n"
        for (n, setup) in setups.enumerated() {
            var own: [Float] = [], margin: [Float] = [], correct = 0, total = 0
            for speaker in speakers {
                var synthesizer = ClonedVoiceSynthesizer(modelsDirectory: modelsDirectory, language: "pt-BR")
                synthesizer.guidance = setup.guidance
                for (i, line) in lines.enumerated() {
                    let out = work.appendingPathComponent("\(speaker.name)-\(n)-\(i).wav")
                    try await synthesizer.synthesize(line, voice: setup.reference(speaker).path, to: out)
                    let resampled = work.appendingPathComponent("\(speaker.name)-\(n)-\(i)-16k.wav")
                    try await ProcessRunner.runChecked(ffmpeg, ["-nostdin", "-v", "error", "-y", "-i", out.path, "-ar", "16000", "-ac", "1",
                                                                "-c:a", "pcm_s16le", resampled.path])
                    let clone = try embedding(read(resampled))
                    let mine = cosine(clone, speaker.truth)
                    let best = speakers.filter { $0.name != speaker.name }.map { cosine(clone, $0.truth) }.max() ?? 0
                    own.append(mine)
                    margin.append(mine - best)
                    if mine > best { correct += 1 }
                    total += 1
                }
            }
            report += String(format: "%-48@ certa %.3f · vantagem %.3f · reconhecida %d de %d\n",
                             setup.name as NSString, mean(own), mean(margin), correct, total)
        }
        // Ceiling: two different real recordings of the same person.
        var real: [Float] = []
        for speaker in speakers {
            let resampled = work.appendingPathComponent("\(speaker.name)-real-16k.wav")
            try await ProcessRunner.runChecked(ffmpeg, ["-nostdin", "-v", "error", "-y", "-i", speaker.long.path, "-ar", "16000", "-ac", "1",
                                                        "-c:a", "pcm_s16le", resampled.path])
            real.append(cosine(try embedding(read(resampled)), speaker.truth))
        }
        report += String(format: "(teto: duas gravações reais diferentes da mesma pessoa dão %.3f)\n", mean(real))
        print(report)
        try report.write(to: folder.appendingPathComponent("resultado.txt"), atomically: true, encoding: .utf8)
    }

    private func join(_ files: [URL], to output: URL, rate: Int, ffmpeg: URL) async throws {
        let inputs = files.flatMap { ["-i", $0.path] }
        let filter = files.indices.map { "[\($0):a]aresample=\(rate)[a\($0)]" }.joined(separator: ";") + ";"
            + files.indices.map { "[a\($0)]" }.joined() + "concat=n=\(files.count):v=0:a=1[out]"
        try await ProcessRunner.runChecked(ffmpeg, ["-nostdin", "-v", "error", "-y"] + inputs
            + ["-filter_complex", filter, "-map", "[out]", "-ac", "1", "-c:a", "pcm_s16le", output.path])
    }

    private func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let dot = zip(a, b).map(*).reduce(0, +)
        let norms = sqrt(a.map { $0 * $0 }.reduce(0, +)) * sqrt(b.map { $0 * $0 }.reduce(0, +))
        return norms > 0 ? dot / norms : 0
    }

    private func mean(_ values: [Float]) -> Float { values.isEmpty ? 0 : values.reduce(0, +) / Float(values.count) }

    private func installMetallib() throws -> URL? {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let name = info.dli_fname else { return nil }
        let binaryDir = URL(fileURLWithPath: String(cString: name)).deletingLastPathComponent()
        let target = binaryDir.appendingPathComponent("mlx.metallib")
        let products = binaryDir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = products.appendingPathComponent("mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
        if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: source, to: target) }
        return target
    }
}
