import DubbingKit
import Foundation
import Observation

public struct Job: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case translate, translateAndMux, mux, dub

        public var label: String {
            switch self {
            case .translate: "Traduzir"
            case .translateAndMux: "Traduzir e incorporar"
            case .mux: "Incorporar faixa"
            case .dub: "Dublar (voice-over)"
            }
        }
    }

    public enum Status: String, Sendable, Codable {
        case pending, running, done, failed, cancelled, interrupted

        public var label: String {
            switch self {
            case .pending: "Na fila"
            case .running: "Em andamento"
            case .done: "Concluído"
            case .failed: "Falhou"
            case .cancelled: "Cancelado"
            case .interrupted: "Interrompido"
            }
        }

        public var isFinished: Bool { self == .done || self == .failed || self == .cancelled }
    }

    public var id: UUID
    public var kind: Kind
    public var mediaPath: String
    public var title: String
    public var seriesID: UUID?
    public var status: Status
    public var progress: Double
    public var message: String
    public var log: [String]
    public var createdAt: Date
    public var finishedAt: Date?
    public var outputPath: String?

    public init(kind: Kind, mediaURL: URL, seriesID: UUID?) {
        id = UUID()
        self.kind = kind
        mediaPath = mediaURL.path
        title = mediaURL.deletingPathExtension().lastPathComponent
        self.seriesID = seriesID
        status = .pending
        progress = 0
        message = "Aguardando"
        log = []
        createdAt = Date()
    }
}

/// Runs one job at a time, in order. Performs the actual work through the `perform` closure;
/// the queue itself only sequences, persists and reports.
public protocol JobPerformer: Sendable {
    /// Returns the output file path, if any.
    func perform(_ job: Job, progress: @escaping @Sendable (Double, String) -> Void) async throws -> String?
}

/// Persistent queue: every change is saved, so quitting (or a crash) keeps the list. Jobs that
/// were running when the app stopped come back as “Interrompido” and resume from their
/// translation checkpoint when started again.
@MainActor
@Observable
public final class JobQueue {
    public private(set) var jobs: [Job] = []
    public private(set) var isRunning = false
    private let file: URL
    private let performer: any JobPerformer
    private let activity: ProjectActivity
    private var current: Task<Void, Never>?
    private var currentID: UUID?
    private var waitingRetry: Task<Void, Never>?

    public init(file: URL, performer: any JobPerformer, activity: ProjectActivity = ProjectActivity()) {
        self.file = file
        self.performer = performer
        self.activity = activity
        jobs = ((try? JSONFile.read([Job].self, from: file)) ?? []).map { job in
            var job = job
            if job.status == .running {
                job.status = .interrupted
                job.message = "Interrompido quando o app foi fechado"
            }
            return job
        }
        persist()
    }

    public var pendingCount: Int { jobs.filter { $0.status == .pending || $0.status == .running }.count }
    public var interruptedCount: Int { jobs.filter { $0.status == .interrupted }.count }

    public func enqueue(_ kind: Job.Kind, mediaURLs: [URL], seriesID: UUID?) {
        for url in mediaURLs { jobs.append(Job(kind: kind, mediaURL: url, seriesID: seriesID)) }
        persist()
        startIfNeeded()
    }

    public func resumeInterrupted() {
        for i in jobs.indices where jobs[i].status == .interrupted || jobs[i].status == .failed || jobs[i].status == .cancelled {
            jobs[i].status = .pending
            jobs[i].progress = 0
            jobs[i].message = "Aguardando (retomada)"
        }
        persist()
        startIfNeeded()
    }

    public func retry(_ id: UUID) {
        update(id) { $0.status = .pending; $0.progress = 0; $0.message = "Aguardando" }
        startIfNeeded()
    }

    public func cancel(_ id: UUID) {
        if currentID == id { current?.cancel() } else { update(id) { if !$0.status.isFinished { $0.status = .cancelled; $0.message = "Cancelado" } } }
    }

    public func cancelAll() {
        for job in jobs where job.status == .pending { update(job.id) { $0.status = .cancelled; $0.message = "Cancelado" } }
        current?.cancel()
    }

    public func removeFinished() {
        jobs.removeAll { $0.status.isFinished }
        persist()
    }

    public func startIfNeeded() {
        guard current == nil, let next = jobs.first(where: { $0.status == .pending }) else { return }
        let projectID = StudioProject.id(for: URL(fileURLWithPath: next.mediaPath))
        guard activity.begin(projectID, "Fila: \(next.kind.label)") else {
            // The open episode is translating or muxing this file; try again shortly.
            update(next.id, save: false) { $0.message = "Aguardando: o episódio está em uso no estúdio" }
            waitingRetry?.cancel()
            waitingRetry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.startIfNeeded()
            }
            return
        }
        isRunning = true
        currentID = next.id
        update(next.id) { $0.status = .running; $0.message = "Iniciando…"; $0.log.append(Self.stamp("Iniciado")) }
        let performer = performer
        current = Task { [weak self] in
            let job = next
            do {
                let output = try await performer.perform(job) { value, message in
                    Task { @MainActor in self?.update(job.id, save: false) { $0.progress = value; $0.message = message } }
                }
                self?.finish(job.id, status: .done, message: "Concluído", output: output)
            } catch is CancellationError {
                self?.finish(job.id, status: .cancelled, message: "Cancelado")
            } catch {
                let text = LogRedactor.redact(error.localizedDescription)
                self?.finish(job.id, status: Task.isCancelled ? .cancelled : .failed, message: text)
            }
        }
    }

    private func finish(_ id: UUID, status: Job.Status, message: String, output: String? = nil) {
        if let job = jobs.first(where: { $0.id == id }) { activity.end(StudioProject.id(for: URL(fileURLWithPath: job.mediaPath))) }
        update(id) { job in
            job.status = status
            job.message = message
            job.finishedAt = Date()
            if status == .done { job.progress = 1 }
            if let output { job.outputPath = output }
            job.log.append(Self.stamp("\(status.label): \(message)"))
        }
        current = nil
        currentID = nil
        isRunning = false
        startIfNeeded()
    }

    private func update(_ id: UUID, save: Bool = true, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
        if save { persist() }
    }

    private func persist() {
        do { try JSONFile.write(jobs, to: file) } catch { AppLog.shared.error("Fila não salva: \(error.localizedDescription)") }
    }

    private static func stamp(_ text: String) -> String { "\(Date().formatted(date: .omitted, time: .standard)) \(text)" }
}

/// The app's performer: translation (resuming checkpoints) and muxing through `EpisodeWorkflow`.
public struct EpisodeJobPerformer: JobPerformer {
    public let paths: AppPaths
    public let settings: @Sendable () -> AppSettings
    public let apiKey: @Sendable (AppSettings) -> String?

    public init(paths: AppPaths, settings: @escaping @Sendable () -> AppSettings, apiKey: @escaping @Sendable (AppSettings) -> String?) {
        self.paths = paths
        self.settings = settings
        self.apiKey = apiKey
    }

    public func perform(_ job: Job, progress: @escaping @Sendable (Double, String) -> Void) async throws -> String? {
        let settings = settings()
        let series = job.seriesID.flatMap { SeriesStore(paths: paths).series($0) }
        let workflow = EpisodeWorkflow(paths: paths, settings: settings, engine: settings.makeEngine(apiKey: apiKey(settings)),
                                       glossary: series?.glossary ?? .init())
        var project = ProjectStore(paths: paths).project(for: URL(fileURLWithPath: job.mediaPath))
        if let id = job.seriesID { project.seriesID = id }
        if job.kind == .dub {
            // Translates what is missing first, then dubs with the series' cast.
            let (translated, _) = try await workflow.translate(project) { progress($0.fraction * 0.3, $0.message) }
            let cast = series?.cast ?? translated.cast ?? VoiceCast()
            let (_, url, _, _) = try await workflow.dub(translated, synthesizer: settings.makeSynthesizer(), cast: cast) {
                progress(0.3 + $0.fraction * 0.7, $0.message)
            }
            return url.path
        }
        let translateShare = job.kind == .translateAndMux ? 0.8 : 1
        if job.kind != .mux {
            let (translated, report) = try await workflow.translate(project) { progress($0.fraction * translateShare, $0.message) }
            project = translated
            if !report.isComplete && job.kind == .translateAndMux {
                throw TranslationPipelineIncomplete(failed: report.failedLines.count)
            }
        }
        guard job.kind != .translate else { return ProjectStore(paths: paths).translationURL(for: project, language: settings.targetLanguage)?.path }
        let (_, url, _) = try await workflow.mux(project) { progress(translateShare + $0.fraction * (1 - translateShare), $0.message) }
        return url.path
    }
}

/// Markdown summary of a season (or any set of jobs): status, output and the numbers of each
/// episode's last translation, dub and verification.
public enum SeasonReport {
    public static func markdown(jobs: [Job], store: ProjectStore, date: Date = Date()) -> String {
        var lines = ["# Relatório de localização", "", "Gerado em \(date.formatted(date: .long, time: .shortened)).", "",
                     "| Episódio | Trabalho | Estado | Traduzidas | Sem tradução | Dublagem | Verificação | Arquivo gerado |",
                     "|---|---|---|---|---|---|---|---|"]
        for job in jobs.sorted(by: { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) {
            let project = store.existingProject(for: URL(fileURLWithPath: job.mediaPath))
            let report = project?.lastReport
            let dub = project?.lastDubReport.map { "\($0.synthesized + $0.reusedClips)/\($0.totalSegments) falas" } ?? "—"
            let verification = project?.lastVerification.map { $0.passed ? "ok" : "falhou" } ?? "—"
            let output = job.outputPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "—"
            let cells = [job.title, job.kind.label, job.status.label, report.map { "\($0.translatedLines)/\($0.totalLines)" } ?? "—",
                         report.map { String($0.failedLines.count) } ?? "—", dub, verification, output]
            lines.append("| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |")
        }
        let failed = jobs.filter { $0.status == .failed }
        if !failed.isEmpty {
            lines += ["", "## Falhas", ""] + failed.map { "- **\($0.title)**: \($0.message)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

public struct TranslationPipelineIncomplete: Error, LocalizedError {
    public let failed: Int
    public var errorDescription: String? { "\(failed) falas ficaram sem tradução; revise no editor antes de incorporar." }
}
