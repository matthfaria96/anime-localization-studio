import Foundation
import Testing
@testable import StudioCore
import TranslationKit

private func tempPaths() -> AppPaths {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("ALSCore-\(UUID().uuidString)", isDirectory: true)
    return AppPaths(root: base.appendingPathComponent("Support"), caches: base.appendingPathComponent("Caches"))
}

private struct InstantPerformer: JobPerformer {
    func perform(_ job: Job, progress: @escaping @Sendable (Double, String) -> Void) async throws -> String? {
        progress(0.5, "meio")
        if job.title.contains("falha") { throw TranslationEngineError.permanent("api_key=sk-proj-abcdefghijklmnop recusada") }
        return "/tmp/\(job.title).mkv"
    }
}

private struct HangingPerformer: JobPerformer {
    func perform(_ job: Job, progress: @escaping @Sendable (Double, String) -> Void) async throws -> String? {
        try await Task.sleep(for: .seconds(30))
        return nil
    }
}

@MainActor
@Suite("Job queue")
struct JobQueueTests {
    @Test func runsJobsInOrderAndPersists() async throws {
        let paths = tempPaths()
        let queue = JobQueue(file: paths.jobs, performer: InstantPerformer())
        queue.enqueue(.translate, mediaURLs: [URL(fileURLWithPath: "/m/ep1.mkv"), URL(fileURLWithPath: "/m/ep2 falha.mkv")], seriesID: nil)
        try await waitUntil { queue.jobs.allSatisfy(\.status.isFinished) }
        #expect(queue.jobs[0].status == .done && queue.jobs[0].outputPath == "/tmp/ep1.mkv")
        #expect(queue.jobs[1].status == .failed)
        #expect(!queue.jobs[1].message.contains("sk-proj"), "secrets must be redacted")
        let reloaded = JobQueue(file: paths.jobs, performer: InstantPerformer())
        #expect(reloaded.jobs.count == 2)
    }

    @Test func runningJobsComeBackInterruptedAndResume() async throws {
        let paths = tempPaths()
        do {
            let queue = JobQueue(file: paths.jobs, performer: HangingPerformer())
            queue.enqueue(.translateAndMux, mediaURLs: [URL(fileURLWithPath: "/m/ep1.mkv")], seriesID: nil)
            #expect(queue.jobs[0].status == .running)
        }
        // A new queue reading the same file simulates relaunching after a crash.
        let relaunched = JobQueue(file: paths.jobs, performer: InstantPerformer())
        #expect(relaunched.jobs[0].status == .interrupted)
        #expect(relaunched.interruptedCount == 1)
        relaunched.resumeInterrupted()
        try await waitUntil { relaunched.jobs[0].status == .done }
    }

    @Test func cancelStopsTheRunningJob() async throws {
        let queue = JobQueue(file: tempPaths().jobs, performer: HangingPerformer())
        queue.enqueue(.translate, mediaURLs: [URL(fileURLWithPath: "/m/a.mkv"), URL(fileURLWithPath: "/m/b.mkv")], seriesID: nil)
        queue.cancelAll()
        try await waitUntil { queue.jobs.allSatisfy(\.status.isFinished) }
        #expect(queue.jobs.allSatisfy { $0.status == .cancelled })
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { Issue.record("timed out"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@Suite("Storage and settings")
struct StorageTests {
    @Test func projectsAreStablePerFile() throws {
        let store = ProjectStore(paths: tempPaths())
        let url = URL(fileURLWithPath: "/Volumes/Anime/Show/Episode 01.mkv")
        var project = store.project(for: url)
        #expect(project.title == "Episode 01")
        project.sourceTrackID = 3
        project.sourceFormat = .ass
        try store.save(project)
        #expect(store.project(for: url).sourceTrackID == 3)
        #expect(store.translationURL(for: project)?.lastPathComponent == "translation.pt-BR.ass")
        #expect(store.all().count == 1)
    }

    @Test func seriesKeepTheirGlossary() throws {
        let store = SeriesStore(paths: tempPaths())
        let series = Series(name: "Sword Art Online", glossary: Glossary(entries: [GlossaryEntry(source: "Kirito", target: "Kirito", kind: .character)]))
        try store.save(series)
        #expect(store.all().first?.glossary.entries.first?.source == "Kirito")
    }

    @Test func settingsSurviveMissingKeys() throws {
        let paths = tempPaths()
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try Data(#"{"engine":"foundationModels","trackName":"PT-BR"}"#.utf8).write(to: paths.settings)
        let settings = SettingsStore(paths: paths).load()
        #expect(settings.engine == .foundationModels)
        #expect(settings.trackName == "PT-BR")
        #expect(settings.targetLanguage == "pt-BR")
        #expect(settings.makeDefault)
    }

    @Test func redactsSecretsAndHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let text = LogRedactor.redact("Authorization: Bearer abc.def-123 key sk-proj-ABCDEFGHIJKLMNOP api_key=\"xyz123\" at \(home)/Movies/a.mkv")
        #expect(!text.contains("abc.def-123"))
        #expect(!text.contains("ABCDEFGHIJKLMNOP"))
        #expect(!text.contains("xyz123"))
        #expect(text.contains("~/Movies/a.mkv"))
    }
}

@Suite("Season report and redaction")
struct SeasonReportTests {
    @Test func reportListsEveryJob() {
        let store = ProjectStore(paths: AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("ALSRep-\(UUID().uuidString)")))
        var failed = Job(kind: .translate, mediaURL: URL(fileURLWithPath: "/m/Ep 02.mkv"), seriesID: nil)
        failed.status = .failed
        failed.message = "quota | acabou"
        let markdown = SeasonReport.markdown(jobs: [failed, Job(kind: .dub, mediaURL: URL(fileURLWithPath: "/m/Ep 01.mkv"), seriesID: nil)], store: store)
        #expect(markdown.contains("| Ep 01 | Dublar (voice-over) | Na fila |"))
        #expect(markdown.contains("## Falhas"))
        #expect(markdown.contains("quota | acabou"))
    }

    @Test func registeredSecretsAreHidden() {
        LogRedactor.register(secret: "AIzaUnprefixedKey123456")
        #expect(!LogRedactor.redact("failed with AIzaUnprefixedKey123456").contains("Unprefixed"))
    }
}

@Suite("Storage inventory")
struct StorageInventoryTests {
    @Test func measuresAndClearsEachKindSeparately() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ALSStorage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let paths = AppPaths(root: base.appendingPathComponent("Support"), caches: base.appendingPathComponent("Caches"))
        let inventory = StorageInventory(paths: paths)
        func write(_ url: URL, bytes: Int) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 7, count: bytes).write(to: url)
        }
        try write(paths.previews.appendingPathComponent("a.mp4"), bytes: 200_000)
        try write(paths.projects.appendingPathComponent("p1/project.json"), bytes: 10_000)
        try write(paths.projects.appendingPathComponent("p1/Dub/clips/1.wav"), bytes: 300_000)
        try write(paths.projects.appendingPathComponent("p2/Dub/background-1.wav"), bytes: 300_000)

        let sizes = Dictionary(uniqueKeysWithValues: inventory.entries().map { ($0.kind, $0.bytes) })
        #expect(sizes[.previews]! >= 200_000)
        #expect(sizes[.dubs]! >= 600_000)
        #expect(sizes[.projects]! < 100_000, "dub files are not counted twice")

        try inventory.clear(.dubs, except: ["p2"])
        #expect(!FileManager.default.fileExists(atPath: paths.projects.appendingPathComponent("p1/Dub").path))
        #expect(FileManager.default.fileExists(atPath: paths.projects.appendingPathComponent("p1/project.json").path), "only the dub files go")
        #expect(FileManager.default.fileExists(atPath: paths.projects.appendingPathComponent("p2/Dub").path), "a busy episode is skipped")

        try inventory.clear(.previews)
        #expect(StorageInventory.size(of: paths.previews) == 0)
    }
}

@Suite("Dub history")
struct DubHistoryTests {
    @Test func historyIsSavedAndOldProjectsStillLoad() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ALSHistory-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ProjectStore(paths: AppPaths(root: base, caches: base.appendingPathComponent("Caches")))
        let media = URL(fileURLWithPath: "/tmp/Show - 01.mkv")
        var project = store.project(for: media)
        #expect(project.dubHistory == nil)
        project.dubHistory = [DubRecord(outputPath: "/tmp/Show - 01 [PT-BR DUB].mkv", replacedOriginal: false, engine: "Voz original",
                                        mode: "Substituir falas", baseAudio: "JA · AAC", language: "pt-BR", lines: 12, failedLines: 0, verified: true)]
        try store.save(project)
        #expect(store.project(for: media).dubHistory?.first?.lines == 12)

        // A project.json written before the history existed.
        let file = store.directory(for: project.id).appendingPathComponent("project.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        json.removeValue(forKey: "dubHistory")
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        #expect(store.project(for: media).dubHistory == nil)
        #expect(store.project(for: media).id == project.id)
    }
}
