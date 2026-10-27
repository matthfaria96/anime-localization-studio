import AppKit
import Foundation
import MediaKit
import StudioCore
import SubtitleKit

/// Deleting an audio or subtitle track from the Visão geral, with the fonts only it used.
extension WorkspaceModel {
    /// Fonts attached to the video that this subtitle uses and no other subtitle of the video
    /// does. Fonts belong to the whole file, so the ones another subtitle needs always stay.
    func fontsOnlyUsed(by track: MediaTrack) async -> [MediaAttachment] {
        guard let info, track.kind == .subtitles, ["ass", "ssa"].contains(track.textSubtitleExtension ?? "") else { return [] }
        let fonts = info.attachments.filter(\.isFont)
        guard !fonts.isEmpty else { return [] }
        let tools = app.tools
        let folder = embeddedFontsDirectory
        // The preview usually extracted the fonts already; extract the missing ones to read their names.
        let missing = fonts.filter { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.fileName).path) }
        if !missing.isEmpty, let mkvextract = tools.locate(.mkvextract) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            _ = try? await ProcessRunner.run(mkvextract, [info.url.path, "attachments"] + missing.map { "\($0.id):\(folder.appendingPathComponent($0.fileName).path)" })
        }
        func used(by subtitle: MediaTrack) async -> Set<String>? {
            guard let ext = subtitle.textSubtitleExtension else { return [] }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("als-fonts-\(UUID().uuidString).\(ext)")
            defer { try? FileManager.default.removeItem(at: temp) }
            guard (try? await TrackExtractor(tools: tools).extractSubtitle(subtitle, from: info, to: temp)) != nil,
                  let document = try? SubtitleDocument.load(temp) else { return nil }
            guard case .ass(let doc) = document else { return [] }
            return Set(doc.usedFonts.map { $0.lowercased() })
        }
        guard let mine = await used(by: track), !mine.isEmpty else { return [] }
        var others: Set<String> = []
        for other in info.tracks(.subtitles) where other.id != track.id {
            // If another subtitle cannot be read, nothing is offered for removal.
            guard let names = await used(by: other) else { return [] }
            others.formUnion(names)
        }
        return fonts.filter { font in
            let names = Self.families(in: [folder.appendingPathComponent(font.fileName)])
            return !names.isDisjoint(with: mine) && names.isDisjoint(with: others)
        }
    }

    func deleteTrack(_ track: MediaTrack, fonts: [MediaAttachment], replaceOriginal: Bool) {
        guard !isBusy, claim("Excluir faixa") else { return }
        editor.flush()
        notice = nil
        operation = RunningOperation(kind: .muxing, fraction: 0, message: "Preparando…")
        let workflow = workflow()
        let project = project
        task = Task {
            do {
                let (updated, output, _) = try await workflow.removeTracks(project, trackIDs: [track.id], attachmentIDs: Set(fonts.map(\.id)),
                                                                            replaceOriginal: replaceOriginal) { step in
                    Task { @MainActor in self.operation?.fraction = step.fraction; self.operation?.message = step.message }
                }
                self.project = updated
                release()
                operation = nil
                let what = "“\(track.name ?? track.kind.label)”" + (fonts.isEmpty ? "" : " e \(Plural.count(fonts.count, "fonte", "fontes"))")
                if replaceOriginal {
                    await reload()
                    notice = (.success, "\(what) excluída deste arquivo, que foi conferido. A versão anterior está na Lixeira.")
                } else {
                    notice = (.success, "Novo arquivo sem \(what): \(output.path). O original não mudou.")
                    noticeAction = ("Mostrar no Finder", { NSWorkspace.shared.activateFileViewerSelecting([output]) })
                }
                return
            } catch is CancellationError {
                notice = (.info, "Cancelado. Nenhum arquivo foi criado ou alterado.")
            } catch {
                notice = (.error, LogRedactor.redact(error.localizedDescription))
            }
            release()
            operation = nil
        }
    }
}
