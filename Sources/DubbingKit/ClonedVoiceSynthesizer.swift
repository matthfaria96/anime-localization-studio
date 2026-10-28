import AVFoundation
import ChatterboxTTS
import Foundation

/// Speaks the output language with a clone of each character's original voice, on the Mac:
/// Chatterbox Multilingual (Resemble AI, MIT) on MLX, through speech-swift (Apache-2.0). It
/// clones from a short reference with no training, and carries the reference's delivery.
/// `voice` is the path of that reference clip (made by `OriginalVoices`): the character's
/// sample, or the original audio of the very line, which carries its emotion too.
/// The model (about 2 GB) is downloaded only after the person confirms.
public struct ClonedVoiceSynthesizer: SpeechSynthesizer {
    public let id: String
    public let modelsDirectory: URL
    /// Chatterbox language code for the output language, or nil when it has none.
    let languageCode: String?
    public let languageName: String
    /// How expressive the delivery is (0.25 calm … 1 very emphatic); 0.5 is the model's default.
    public var expressiveness: Float = 0.6
    /// How closely the speech follows the reference's way of speaking (Chatterbox `cfg_weight`).
    var guidance: Float = 0.5

    public static let downloadSize = "cerca de 2 GB"
    public static let modelCredits = "Chatterbox Multilingual da Resemble AI (MIT), pelo speech-swift (Apache-2.0)"

    public init(modelsDirectory: URL, language: String = "pt-BR") {
        self.modelsDirectory = modelsDirectory
        languageCode = Self.code(for: language)
        languageName = Locale(identifier: "pt_BR").localizedString(forLanguageCode: String(language.prefix(2))) ?? language
        id = "chatterbox-\(languageCode ?? "none")"
    }

    /// `pt-BR` → `pt`, when Chatterbox speaks it.
    static func code(for language: String) -> String? {
        let code = String(language.split(separator: "-").first ?? Substring(language)).lowercased()
        return MTLTokenizer.supportedLanguages.contains(code) ? code : nil
    }

    /// Output languages the on-device clone can speak (23, Portuguese and Japanese included).
    public static func supports(_ language: String) -> Bool { code(for: language) != nil }

    /// Whether the model is already on disk.
    public var modelsInstalled: Bool {
        FileManager.default.fileExists(atPath: modelsDirectory.appendingPathComponent("model.safetensors").path)
    }

    public func synthesize(_ text: String, voice: String, to url: URL) async throws {
        guard let languageCode else { throw unsupported }
        do {
            let samples = try await ChatterboxEngine.shared.speak(text, reference: URL(fileURLWithPath: voice), language: languageCode,
                                                                   expressiveness: expressiveness, guidance: guidance, modelsDirectory: modelsDirectory)
            guard !samples.isEmpty else { throw SynthesisError.failed("a voz não gerou áudio") }
            try Self.writeWAV(samples, sampleRate: 24_000, to: url)
        } catch let error as SynthesisError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SynthesisError.failed(error.localizedDescription)
        }
    }

    /// Downloads (when missing) and loads the model, ahead of a dub.
    public func prepare(progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard languageCode != nil else { throw unsupported }
        try await ChatterboxEngine.shared.load(modelsDirectory: modelsDirectory, progress: progress)
    }

    private var unsupported: SynthesisError {
        .engineUnavailable("A voz do Mac ainda não fala \(languageName). Para esse idioma, use a ElevenLabs.")
    }

    static func writeWAV(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw SynthesisError.failed("não foi possível preparar o áudio")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}

/// One loaded model for the whole app, and the reference clips already read. Character
/// samples are reused for many lines; line clips once, so only a few are kept.
actor ChatterboxEngine {
    static let shared = ChatterboxEngine()
    private var model: ChatterboxTTSModel?
    private var loadedFrom: URL?
    private var references: [URL: (samples: [Float], rate: Int)] = [:]
    private var recent: [URL] = []
    private let keep = 24

    func load(modelsDirectory: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if model != nil, loadedFrom == modelsDirectory { return }
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        var handler: ((Double, String) -> Void)?
        if let progress { handler = { value, _ in progress(value) } }
        model = try await ChatterboxTTSModel.fromPretrained(cacheDir: modelsDirectory, progressHandler: handler)
        loadedFrom = modelsDirectory
        references = [:]
        recent = []
    }

    func speak(_ text: String, reference: URL, language: String, expressiveness: Float, guidance: Float,
               modelsDirectory: URL) async throws -> [Float] {
        try await load(modelsDirectory: modelsDirectory)
        guard let model else { throw SynthesisError.engineUnavailable("O modelo de voz não carregou.") }
        let ref = try referenceSamples(reference)
        try Task.checkCancellation()
        return try model.clone(referenceSamples: ref.samples, sampleRate: ref.rate, text: text, languageId: language,
                               exaggeration: expressiveness, cfgWeight: guidance)
    }

    private func referenceSamples(_ url: URL) throws -> (samples: [Float], rate: Int) {
        if let cached = references[url] { touch(url); return cached }
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw SynthesisError.failed("a referência de voz não pôde ser lida")
        }
        try file.read(into: buffer)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let value = (samples, Int(file.processingFormat.sampleRate))
        references[url] = value
        touch(url)
        return value
    }

    private func touch(_ url: URL) {
        recent.removeAll { $0 == url }
        recent.append(url)
        while recent.count > keep { references[recent.removeFirst()] = nil }
    }
}
