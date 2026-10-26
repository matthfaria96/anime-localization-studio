import AudioToolbox
import AVFoundation
import Foundation
import MediaKit

/// Splits dialogue from the rest of a soundtrack on the Mac itself, with Apple's
/// `AUSoundIsolation` audio unit in its high-quality voice mode (macOS 15+, no download).
/// The unit isolates the voice; the background (music and effects) is the original minus that
/// voice, time-aligned by compensating the unit's latency. Measured on a synthetic mix, the
/// dialogue left in the background is about 18 dB below the original speech; dense real
/// soundtracks leave more residue, so the result is a good approximation, not a clean stem.
public struct VoiceSeparator: Sendable {
    public let tools: ToolLocator

    public init(tools: ToolLocator) { self.tools = tools }

    public enum SeparationError: Error, LocalizedError {
        case unitUnavailable
        case renderFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unitUnavailable: "O isolamento de voz da Apple (AUSoundIsolation) não está disponível neste Mac."
            case .renderFailed(let m): "A separação de voz falhou: \(m)"
            }
        }
    }

    /// Writes `voice` (isolated dialogue) and `background` (original minus dialogue) from a
    /// 48 kHz WAV.
    public func separate(_ input: URL, voice: URL, background: URL, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try isolateVoice(input, to: voice, progress: progress)
        let ffmpeg = try tools.require(.ffmpeg)
        try await ProcessRunner.runChecked(ffmpeg, ["-nostdin", "-v", "error", "-y", "-i", input.path, "-i", voice.path,
                                                    "-filter_complex", "[1:a]volume=-1[neg];[0:a][neg]amix=inputs=2:normalize=0:duration=first",
                                                    "-c:a", "pcm_s16le", background.path])
    }

    /// Offline render through AUSoundIsolation, dropping the unit's latency from the start so
    /// the isolated voice lines up sample for sample with the input.
    func isolateVoice(_ input: URL, to output: URL, progress: (@Sendable (Double) -> Void)?) throws {
        let file = try AVAudioFile(forReading: input)
        let format = file.processingFormat
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let description = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard AudioComponentFindNext(nil, [description]) != nil else { throw SeparationError.unitUnavailable }
        let isolation = AVAudioUnitEffect(audioComponentDescription: description)
        engine.attach(player)
        engine.attach(isolation)
        try engine.connectNode(player, to: isolation, format: format)
        try engine.connectNode(isolation, to: engine.mainMixerNode, format: format)
        isolation.withAudioUnit { (unit: borrowing AudioUnit) in
            AudioUnitSetParameter(unit, AudioUnitParameterID(kAUSoundIsolationParam_SoundToIsolate), kAudioUnitScope_Global, 0,
                                  AudioUnitParameterValue(kAUSoundIsolationSoundType_HighQualityVoice), 0)
            AudioUnitSetParameter(unit, AudioUnitParameterID(kAUSoundIsolationParam_WetDryMixPercent), kAudioUnitScope_Global, 0, 100, 0)
        }
        let chunk: AVAudioFrameCount = 8_192
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: chunk)
        try engine.start()
        defer { engine.stop() }
        player.scheduleFile(file, at: nil)
        try player.playAudio()

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAudioFile(forWriting: output, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: chunk) else {
            throw SeparationError.renderFailed("buffer")
        }
        let latencySeconds = isolation.withAUAudioUnit { (unit: borrowing AUAudioUnit) in unit.latency }
        let latency = AVAudioFramePosition((latencySeconds * format.sampleRate).rounded())
        let end = file.length + latency
        var toSkip = latency
        var lastReport = 0.0
        while engine.manualRenderingSampleTime < end {
            let frames = AVAudioFrameCount(min(Int64(chunk), end - engine.manualRenderingSampleTime))
            let status = try engine.renderOffline(frames, to: buffer)
            guard status == .success else { throw SeparationError.renderFailed("estado \(status.rawValue)") }
            var slice = buffer
            if toSkip > 0 {
                let skip = min(toSkip, AVAudioFramePosition(buffer.frameLength))
                toSkip -= skip
                guard let rest = Self.dropFirst(AVAudioFrameCount(skip), of: buffer) else { continue }
                slice = rest
            }
            try writer.write(from: slice)
            let fraction = Double(engine.manualRenderingSampleTime) / Double(max(1, end))
            if fraction - lastReport > 0.01 { lastReport = fraction; progress?(fraction) }
        }
    }

    private static func dropFirst(_ count: AVAudioFrameCount, of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard count < buffer.frameLength, let channels = buffer.floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength - count),
              let target = copy.floatChannelData else { return nil }
        copy.frameLength = buffer.frameLength - count
        let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
        let planes = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
        for plane in 0..<planes {
            (target[plane]).update(from: channels[plane].advanced(by: Int(count) * stride), count: Int(copy.frameLength) * stride)
        }
        return copy
    }
}
