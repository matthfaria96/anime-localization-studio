import DubbingKit
import Foundation
import MediaKit

/// Dubbing with ElevenLabs: only the chosen audio track goes up; the dubbed audio comes back
/// and is added to the MKV with the same verification as every other write.
extension EpisodeWorkflow {
    public struct OnlineDubResult: Sendable {
        public let project: StudioProject
        public let output: URL
        public let verification: VerificationReport
        public let dubbingID: String
    }

    public func dubWithElevenLabs(_ project: StudioProject, client: ElevenLabsDubbing, audioTrackID: Int?, replaceOriginal: Bool,
                                  progress: @escaping @Sendable (WorkflowStep) -> Void) async throws -> OnlineDubResult {
        var project = project
        progress(WorkflowStep(fraction: 0.01, message: "Analisando faixas…"))
        let info = try await MediaInspector(tools: tools).inspect(project.mediaURL)
        guard let audio = audioTrackID.flatMap({ id in info.tracks.first { $0.id == id } }) ?? info.tracks(.audio).first(where: \.isDefault) ?? info.tracks(.audio).first,
              let ordinal = info.ordinal(of: audio) else { throw WorkflowError.noAudio }
        let ffmpeg = try tools.require(.ffmpeg)
        let work = store.directory(for: project.id).appendingPathComponent("Dub", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let language = settings.targetLanguage

        // A dub sent before (and maybe paid) for the same audio and language is picked up again.
        let job: ElevenLabsDubbing.Job
        if let pending = project.remoteDub, pending.language == language, pending.audioTrackID == audio.id {
            job = ElevenLabsDubbing.Job(dubbing_id: pending.id, expected_duration_sec: pending.expectedSeconds)
            progress(WorkflowStep(fraction: 0.2, message: "Retomando a dublagem que já estava na ElevenLabs…"))
        } else {
            progress(WorkflowStep(fraction: 0.03, message: "Preparando o áudio para enviar…"))
            let upload = work.appendingPathComponent("upload-\(audio.id).m4a")
            try await ProcessRunner.runChecked(ffmpeg, ["-nostdin", "-v", "error", "-y", "-i", info.url.path, "-map", "0:a:\(ordinal)", "-vn",
                                                        "-map_chapters", "-1", "-map_metadata", "-1", "-c:a", "aac", "-b:a", "160k", upload.path])
            defer { try? FileManager.default.removeItem(at: upload) }
            progress(WorkflowStep(fraction: 0.1, message: "Enviando o áudio para a ElevenLabs…"))
            job = try await client.createDub(audio: upload, name: project.title, targetLanguage: language,
                                             sourceLanguage: settings.dubbingSourceLanguage)
            project.remoteDub = RemoteDub(id: job.dubbing_id, language: language, audioTrackID: audio.id, expectedSeconds: job.expected_duration_sec)
            try store.save(project)
        }

        try await client.waitUntilDubbed(job) { value in
            progress(WorkflowStep(fraction: 0.2 + value * 0.65, message: "A ElevenLabs está separando as vozes, traduzindo e dublando…"))
        }
        progress(WorkflowStep(fraction: 0.86, message: "Baixando o áudio dublado…"))
        let downloaded = work.appendingPathComponent("elevenlabs-\(job.dubbing_id).bin")
        try await client.downloadAudio(job.dubbing_id, language: language, to: downloaded)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        let dubAudio = store.directory(for: project.id).appendingPathComponent("dub.\(language).elevenlabs.m4a")
        try await ProcessRunner.runChecked(ffmpeg, ["-nostdin", "-v", "error", "-y", "-i", downloaded.path, "-vn",
                                                    "-map_chapters", "-1", "-map_metadata", "-1", "-c:a", "aac", "-b:a", "192k", dubAudio.path])

        let track = NewTrack(file: dubAudio, kind: .audio, language: language,
                             name: "\(Self.trackName(for: language)) · dublagem ElevenLabs", isDefault: settings.makeDefault)
        var plan = MuxPlan(source: info, output: MuxPlan.defaultOutputURL(for: project.mediaURL, suffix: "\(language.uppercased()) DUB"),
                           newTracks: [track], clearOtherDefaults: settings.makeDefault, placeNewTracksFirst: settings.placeNewTrackFirst)
        plan.replaceSource = replaceOriginal
        let (url, verification) = try await MKVMuxer(tools: tools).mux(plan) { value in
            progress(WorkflowStep(fraction: 0.9 + value * 0.1, message: value < 0.9 ? "Gravando o MKV…" : "Verificando integridade…"))
        }
        project.remoteDub = nil
        project.dubbingStatus = .muxed
        if replaceOriginal {
            if let output = verification.outputInfo { Self.remapTrackIDs(&project, from: info, removed: [], to: output) }
            project.mediaFingerprint = Self.fingerprint(of: url)
        }
        project.lastOutputPath = url.path
        project.lastVerification = verification
        try store.save(project)
        return OnlineDubResult(project: project, output: url, verification: verification, dubbingID: job.dubbing_id)
    }
}
