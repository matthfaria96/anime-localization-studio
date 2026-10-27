import Foundation
import Testing
@testable import MediaKit
import SubtitleKit

@Suite("Media pipeline (real MKVToolNix + FFmpeg)", .enabled(if: hasMediaTools), .serialized)
struct MediaPipelineTests {
    @Test func inspectsTracksAttachmentsAndChapters() async throws {
        let dir = MediaFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let episode = try await MediaFixtures.makeEpisode(in: dir)
        let info = try await MediaInspector(tools: testTools).inspect(episode)
        #expect(info.isMatroska)
        #expect(info.tracks(.video).count == 1)
        #expect(info.tracks(.audio).count == 2)
        #expect(info.tracks(.subtitles).count == 1)
        #expect(info.attachments.count == 1 && info.attachments[0].isFont)
        #expect(info.chapterCount == 2)
        #expect(info.tracks(.video)[0].width == 640)
        let sub = try #require(info.bestSourceSubtitle())
        #expect(sub.textSubtitleExtension == "ass")
        #expect(sub.name == "English (Full)")
        #expect(info.tracks(.audio)[0].languageIETF == "ja")
        #expect((info.durationMilliseconds ?? 0) > 2_500)
    }

    @Test func extractsTheAssTrackWithItsStructure() async throws {
        let dir = MediaFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let episode = try await MediaFixtures.makeEpisode(in: dir)
        let info = try await MediaInspector(tools: testTools).inspect(episode)
        let track = try #require(info.bestSourceSubtitle())
        let out = try await TrackExtractor(tools: testTools).extractSubtitle(track, from: info, to: dir.appendingPathComponent("x/source.ass"))
        let doc = try SubtitleDocument.load(out)
        #expect(doc.count == 2)
        #expect(doc.rawText(at: 1) == #"{\an8}Wait, {\i1}where{\i0} are you going?"#)
        guard case .ass(let ass) = doc else { Issue.record("not ASS"); return }
        #expect(ass.playResolution.width == 640)
        #expect(ass.style(named: "Default")?["Fontname"] == "Arial")
    }

    @Test func addsPortugueseTrackWithoutTouchingTheOriginal() async throws {
        let dir = MediaFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let episode = try await MediaFixtures.makeEpisode(in: dir)
        let originalHash = try MediaFixtures.sha256(episode)
        let info = try await MediaInspector(tools: testTools).inspect(episode)
        let track = try #require(info.bestSourceSubtitle())
        let extracted = try await TrackExtractor(tools: testTools).extractSubtitle(track, from: info, to: dir.appendingPathComponent("w/source.ass"))
        var doc = try SubtitleDocument.load(extracted)
        doc.setRawText("Eu não vou deixar você machucar meus amigos!", at: 0)
        doc.setRawText(#"{\an8}Espera, {\i1}aonde{\i0} você vai?"#, at: 1)
        let translated = dir.appendingPathComponent("w/pt-BR.ass")
        try doc.write(to: translated)

        let plan = MuxPlan(source: info, output: MuxPlan.defaultOutputURL(for: episode),
                           newTracks: [NewTrack(file: translated, kind: .subtitles, language: "pt-BR", name: "Português (Brasil)", isDefault: true)])
        let progress = ProgressBox()
        let (output, report) = try await MKVMuxer(tools: testTools).mux(plan) { progress.set($0) }
        #expect(report.passed, "\(report.failures)")
        #expect(output.lastPathComponent == "Episode 01 – teste ['$&] [PT-BR].mkv")
        #expect(progress.value == 1)
        #expect(try MediaFixtures.sha256(episode) == originalHash)
        #expect(report.checks.contains { $0.title == "Vídeo sem recodificação" && $0.passed })

        let result = try #require(report.outputInfo)
        let subs = result.tracks(.subtitles)
        #expect(subs.count == 2)
        #expect(subs.contains { $0.name == "English (Full)" && !$0.isDefault })
        #expect(subs.contains { $0.languageIETF == "pt-BR" && $0.isDefault })
        #expect(result.attachments.count == 1)

        // The embedded Portuguese track comes back out identical in its events.
        let pt = try #require(subs.first { $0.languageIETF == "pt-BR" })
        let roundTrip = try await TrackExtractor(tools: testTools).extractSubtitle(pt, from: result, to: dir.appendingPathComponent("w/back.ass"))
        let back = try SubtitleDocument.load(roundTrip)
        #expect(back.rawText(at: 1) == #"{\an8}Espera, {\i1}aonde{\i0} você vai?"#)

        // A second run never overwrites the first result.
        let (second, _) = try await MKVMuxer(tools: testTools).mux(plan)
        #expect(second.lastPathComponent == "Episode 01 – teste ['$&] [PT-BR] (2).mkv")
    }

    @Test func changesDefaultTracksInPlaceOrInACopy() async throws {
        let dir = MediaFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let episode = try await MediaFixtures.makeEpisode(in: dir)
        let info = try await MediaInspector(tools: testTools).inspect(episode)
        let english = info.tracks(.audio)[1]
        let originalHash = try MediaFixtures.sha256(episode)
        // Copy: the original keeps Japanese as default.
        let copy = try await TrackFlagEditor(tools: testTools).apply(.init(audioTrackID: english.id, subtitleTrackID: -1), to: info,
                                                                    copyTo: dir.appendingPathComponent("copy.mkv"))
        #expect(try MediaFixtures.sha256(episode) == originalHash)
        let copied = try await MediaInspector(tools: testTools).inspect(copy)
        #expect(copied.tracks(.audio).filter(\.isDefault).map(\.id) == [english.id])
        #expect(copied.tracks(.subtitles).allSatisfy { !$0.isDefault })
        // In place.
        try await TrackFlagEditor(tools: testTools).apply(.init(audioTrackID: english.id, subtitleTrackID: nil), to: info)
        let edited = try await MediaInspector(tools: testTools).inspect(episode)
        #expect(edited.tracks(.audio).filter(\.isDefault).map(\.id) == [english.id])
        #expect(edited.tracks(.subtitles).first?.isDefault == true)
        // Video untouched by a header edit.
        #expect(try await IntegrityVerifier(tools: testTools).samePackets(copy, episode).0)
    }

    @Test func replacesTheSourceOnlyAfterVerification() async throws {
        let dir = MediaFixtures.temporaryDirectory()
        let trash = dir.appendingPathComponent("Trash")
        defer { try? FileManager.default.removeItem(at: dir) }
        setenv("ALS_TRASH_DIR", trash.path, 1)
        defer { unsetenv("ALS_TRASH_DIR") }
        let episode = try await MediaFixtures.makeEpisode(in: dir)
        let info = try await MediaInspector(tools: testTools).inspect(episode)
        let subtitle = dir.appendingPathComponent("pt.ass")
        try MediaFixtures.ass.write(to: subtitle, atomically: true, encoding: .utf8)
        var plan = MuxPlan(source: info, output: episode, newTracks: [NewTrack(file: subtitle, kind: .subtitles, name: "Português (Brasil)")])
        plan.replaceSource = true
        let (output, report) = try await MKVMuxer(tools: testTools).mux(plan)
        #expect(report.passed && output == episode)
        let replaced = try await MediaInspector(tools: testTools).inspect(episode)
        #expect(replaced.tracks(.subtitles).count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: trash.path) == [episode.lastPathComponent])
    }

    @Test func addedFilesNeverBringTheirChapters() async throws {
        let dir = MediaFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let episode = try await MediaFixtures.makeEpisode(in: dir)
        let info = try await MediaInspector(tools: testTools).inspect(episode)
        // An audio file made from the episode by FFmpeg without -map_chapters -1 carries its chapters.
        let audio = dir.appendingPathComponent("dub.m4a")
        try await ProcessRunner.runChecked(try testTools.require(.ffmpeg), ["-nostdin", "-v", "error", "-y", "-i", episode.path, "-map", "0:a:0", "-c:a", "aac", audio.path])
        let plan = MuxPlan(source: info, output: dir.appendingPathComponent("out.mkv"),
                           newTracks: [NewTrack(file: audio, kind: .audio, name: "Dublado")])
        let (_, report) = try await MKVMuxer(tools: testTools).mux(plan)
        #expect(report.passed, "\(report.failures)")
        #expect(report.outputInfo?.chapterCount == info.chapterCount)
    }

    @Test func verificationCatchesReencodedVideo() async throws {
        let dir = MediaFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let episode = try await MediaFixtures.makeEpisode(in: dir)
        let info = try await MediaInspector(tools: testTools).inspect(episode)
        let reencoded = dir.appendingPathComponent("reencoded.mkv")
        try await ProcessRunner.runChecked(try testTools.require(.ffmpeg), ["-nostdin", "-v", "error", "-y", "-i", episode.path, "-map", "0",
                                                                             "-c", "copy", "-c:v", "libx264", "-preset", "ultrafast", "-crf", "30", reencoded.path])
        let same = try await IntegrityVerifier(tools: testTools).samePackets(episode, reencoded)
        #expect(same.0 == false)
    }

    @Test func buildsAPlayablePreview() async throws {
        let dir = MediaFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let episode = try await MediaFixtures.makeEpisode(in: dir)
        let info = try await MediaInspector(tools: testTools).inspect(episode)
        let proxy = PreviewProxy(tools: testTools, cacheDirectory: dir.appendingPathComponent("cache"))
        let (url, mode) = try await proxy.make(for: info, audioTrack: info.tracks(.audio).first)
        #expect(mode == .copiedVideo)
        let preview = try await MediaInspector(tools: testTools).inspect(url)
        #expect(preview.tracks(.video).count == 1 && preview.tracks(.audio).count == 1)
        // Cached: a second request returns the same file without running FFmpeg again.
        let again = try await proxy.make(for: info, audioTrack: info.tracks(.audio).first)
        #expect(again.0 == url)
    }

    @Test func refusesToWriteOverTheSource() async throws {
        let dir = MediaFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let episode = try await MediaFixtures.makeEpisode(in: dir)
        let info = try await MediaInspector(tools: testTools).inspect(episode)
        let plan = MuxPlan(source: info, output: episode, newTracks: [])
        await #expect(throws: MuxError.outputIsSource) { try await MKVMuxer(tools: testTools).mux(plan) }
    }
}

@Suite("Media helpers")
struct MediaHelperTests {
    @Test func parsesProgressAndVersions() {
        #expect(MKVMuxer.parseGUIProgress("#GUI#progress 42%") == 0.42)
        #expect(MKVMuxer.parseGUIProgress("Progress: 42%") == nil)
        #expect(ToolLocator.shortVersion("mkvmerge v103.0 ('The Darkness') 64-bit", tool: .mkvmerge) == "103.0")
        #expect(ToolLocator.shortVersion("ffmpeg version 9.0.2 Copyright (c) 2000-2026", tool: .ffmpeg) == "9.0.2")
        #expect(FFmpegProgress.fraction("out_time_us=1500000", durationMilliseconds: 3_000) == 0.5)
    }

    @Test func trackOrderPlacesNewTracksByKind() {
        let info = MediaInfo(url: URL(fileURLWithPath: "/a.mkv"), container: "Matroska", tracks: [
            MediaTrack(id: 0, kind: .video, codec: "", codecID: "V_MPEG4/ISO/AVC"),
            MediaTrack(id: 1, kind: .audio, codec: "", codecID: "A_AAC", isDefault: true),
            MediaTrack(id: 2, kind: .subtitles, codec: "", codecID: "S_TEXT/ASS", isDefault: true)
        ])
        let new = NewTrack(file: URL(fileURLWithPath: "/pt.ass"), kind: .subtitles, name: "PT")
        var plan = MuxPlan(source: info, output: URL(fileURLWithPath: "/b.mkv"), newTracks: [new])
        #expect(MKVMuxer.trackOrder(for: plan) == "0:0,0:1,0:2,1:0")
        plan.placeNewTracksFirst = true
        #expect(MKVMuxer.trackOrder(for: plan) == "0:0,0:1,1:0,0:2")
        let args = MKVMuxer.arguments(for: plan, output: URL(fileURLWithPath: "/tmp/o.mkv"))
        #expect(args.contains("2:0"))       // the old default subtitle is cleared
        #expect(!args.contains("1:0") || args.firstIndex(of: "1:0")! > args.firstIndex(of: "/a.mkv")!)
        #expect(args.contains("0:pt-BR"))
    }

    @Test func picksDialogueOverSigns() {
        let info = MediaInfo(url: URL(fileURLWithPath: "/a.mkv"), container: "Matroska", tracks: [
            MediaTrack(id: 2, kind: .subtitles, codec: "", codecID: "S_TEXT/ASS", language: "eng", name: "Signs & Songs", isForced: true),
            MediaTrack(id: 3, kind: .subtitles, codec: "", codecID: "S_TEXT/ASS", language: "eng", name: "Full Subtitles"),
            MediaTrack(id: 4, kind: .subtitles, codec: "", codecID: "S_HDMV/PGS", language: "eng"),
            MediaTrack(id: 5, kind: .subtitles, codec: "", codecID: "S_TEXT/ASS", language: "por", name: "Português")
        ])
        #expect(info.bestSourceSubtitle()?.id == 3)
        #expect(info.tracks(.subtitles)[2].isBitmapSubtitle)
    }

    @Test func freeSpaceIgnoresVolumesThatReportZero() {
        // exFAT: "important usage" says 0 while the volume has 1 TB free.
        #expect(FileOps.bestCapacity(importantUsage: 0, available: 1_082_454_000_000, fileSystem: 1_082_454_000_000) == 1_082_454_000_000)
        #expect(FileOps.bestCapacity(importantUsage: 48_000_000_000, available: 43_000_000_000, fileSystem: 43_000_000_000) == 48_000_000_000)
        #expect(FileOps.bestCapacity(importantUsage: 0, available: 0, fileSystem: nil) == nil)
        #expect(FileOps.availableCapacity(at: FileManager.default.temporaryDirectory).map { $0 > 0 } == true)
    }

    @Test func uniqueNamesNeverOverwrite() throws {
        let dir = MediaFixtures.temporaryDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("A.mkv")
        #expect(FileOps.uniqueURL(for: a) == a)
        try Data().write(to: a)
        #expect(FileOps.uniqueURL(for: a).lastPathComponent == "A (2).mkv")
    }

    @Test func runnerCancelsLongProcesses() async throws {
        let task = Task { try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), ["30"]) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: ProcessError.cancelled) { try await task.value }
    }
}

final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0.0
    var value: Double { lock.withLock { current } }
    func set(_ v: Double) { lock.withLock { current = v } }
}

/// Muxes onto another volume (e.g. an exFAT drive): `ALS_MUX_TEST_DIR=/Volumes/Drive swift test --filter OtherVolume`.
@Suite("Mux on another volume", .enabled(if: hasMediaTools && ProcessInfo.processInfo.environment["ALS_MUX_TEST_DIR"] != nil))
struct OtherVolumeMuxTests {
    @Test func muxesAndVerifiesOnTheGivenVolume() async throws {
        let base = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ALS_MUX_TEST_DIR"]!)
            .appendingPathComponent(".als-mux-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let episode = try await MediaFixtures.makeEpisode(in: base)
        let info = try await MediaInspector(tools: testTools).inspect(episode)
        let subtitle = base.appendingPathComponent("pt.ass")
        try MediaFixtures.ass.replacingOccurrences(of: "my friends", with: "meus amigos").write(to: subtitle, atomically: true, encoding: .utf8)
        #expect((FileOps.availableCapacity(at: base) ?? 0) > 0)
        let plan = MuxPlan(source: info, output: MuxPlan.defaultOutputURL(for: episode),
                           newTracks: [NewTrack(file: subtitle, kind: .subtitles, language: "pt-BR", name: "Português (Brasil)")])
        let (output, report) = try await MKVMuxer(tools: testTools).mux(plan)
        #expect(report.passed, "\(report.failures)")
        #expect(FileManager.default.fileExists(atPath: output.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: base.path).filter { $0.contains(".partial") }
        #expect(leftovers.isEmpty)
    }
}

@Suite("Replacing a track", .enabled(if: hasMediaTools))
struct ReplaceTrackTests {
    @Test func editedSubtitleTakesThePlaceOfTheOldOne() async throws {
        let dir = MediaFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let episode = try await MediaFixtures.makeEpisode(in: dir)
        let info = try await MediaInspector(tools: testTools).inspect(episode)
        let old = try #require(info.tracks(.subtitles).first)
        let edited = dir.appendingPathComponent("edited.ass")
        try MediaFixtures.ass.replacingOccurrences(of: "my friends", with: "my dear friends").write(to: edited, atomically: true, encoding: .utf8)
        var plan = MuxPlan(source: info, output: dir.appendingPathComponent("out.mkv"),
                           newTracks: [NewTrack(file: edited, kind: .subtitles, language: old.languageIETF ?? old.language, name: old.name ?? "", isDefault: old.isDefault)],
                           clearOtherDefaults: false)
        plan.excludedTrackIDs = [old.id]
        let (_, report) = try await MKVMuxer(tools: testTools).mux(plan)
        #expect(report.passed, "\(report.failures)")
        let subs = try #require(report.outputInfo).tracks(.subtitles)
        #expect(subs.count == 1 && subs[0].name == "English (Full)")
    }
}
