import AppKit
import Foundation
import MediaKit
import StudioCore
import SubtitleKit
import UniformTypeIdentifiers

/// The overview's track actions and the “edit an existing subtitle” task.
extension WorkspaceModel {
    // MARK: What the person is doing in Legendar

    func chooseSubtitleTask(_ task: SubtitleTask?) {
        editor.flush()
        project.subtitleTask = task
        try? store.save(project)
        overlayMode = task == .edit ? .original : .translation
        editor.editsOriginal = task == .edit
        notice = nil
    }

    var isEditingOriginal: Bool { project.subtitleTask == .edit }

    // MARK: Extracting a track

    /// Saves one track as its own file (subtitles keep their ASS header; audio and video are
    /// copied as they are, never converted).
    func extractTrack(_ track: MediaTrack) {
        guard let info, !isBusy else { return }
        let ext = track.nativeFileExtension
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        panel.nameFieldStringValue = "\(title).\(track.id).\(track.displayLanguage).\(ext)"
        panel.directoryURL = url.deletingLastPathComponent()
        panel.message = "Onde salvar a faixa “\(Self.describe(track))”? O arquivo original não é alterado."
        guard panel.runModal() == .OK, let destination = panel.url, claim("Extração de faixa") else { return }
        notice = nil
        operation = RunningOperation(kind: .extracting, fraction: 0, message: "Extraindo a faixa…")
        let tools = app.tools
        task = Task {
            do {
                let progress: @Sendable (Double) -> Void = { value in Task { @MainActor in self.operation?.fraction = value } }
                let extractor = TrackExtractor(tools: tools)
                let file = track.textSubtitleExtension != nil
                    ? try await extractor.extractSubtitle(track, from: info, to: destination, progress: progress)
                    : try await extractor.extractRaw(track, from: info, to: destination, progress: progress)
                notice = (.success, "Faixa salva em \(file.path).")
                noticeAction = ("Mostrar no Finder", { NSWorkspace.shared.activateFileViewerSelecting([file]) })
            } catch is CancellationError {
                notice = (.info, "Extração cancelada.")
            } catch {
                notice = (.error, LogRedactor.redact(error.localizedDescription))
            }
            release()
            operation = nil
        }
    }

    // MARK: Saving an edited subtitle

    func requestSaveEdited() {
        guard !isBusy, editor.source != nil else { return }
        editor.flush()
        askSaveEditedDestination = true
    }

    /// Puts the corrected subtitle in the MKV in place of the track it came from.
    func saveEditedSubtitle(replaceOriginal: Bool) {
        guard !isBusy, editor.source != nil, claim("Salvar a legenda editada") else { return }
        editor.flush()
        notice = nil
        operation = RunningOperation(kind: .muxing, fraction: 0, message: "Preparando…")
        let workflow = workflow()
        let project = project
        task = Task {
            do {
                let (updated, output, report) = try await workflow.saveEditedSubtitle(project, replaceOriginal: replaceOriginal) { step in
                    Task { @MainActor in self.operation?.fraction = step.fraction; self.operation?.message = step.message }
                }
                self.project = updated
                lastMux = (output, report)
                release()
                operation = nil
                if replaceOriginal {
                    await reload()
                    notice = (.success, "Legenda corrigida gravada no próprio arquivo, no lugar da antiga. A versão anterior do arquivo está na Lixeira.")
                } else {
                    notice = (.success, "Novo arquivo com a legenda corrigida: \(output.path). O original não foi alterado.")
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

    func exportSource() {
        guard let source = editor.source, let format = project.sourceFormat else { return }
        editor.flush()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .plainText]
        panel.nameFieldStringValue = "\(project.title).\(format.fileExtension)"
        panel.directoryURL = url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try source.write(to: destination)
            notice = (.success, "Legenda salva em \(destination.path).")
            noticeAction = ("Mostrar no Finder", { NSWorkspace.shared.activateFileViewerSelecting([destination]) })
        } catch {
            app.report(error, context: "A legenda não foi salva")
        }
    }
}
