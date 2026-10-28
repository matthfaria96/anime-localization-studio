import AppKit
import CoreText
import MediaKit
import StudioCore
import UniformTypeIdentifiers

/// One font the subtitle asks for, and where it comes from.
struct FontStatus: Identifiable, Hashable {
    enum Source { case attached, added, installed, missing }
    let family: String
    let source: Source
    var id: String { family }
}

/// Fonts of the subtitle: attached to the video, added in the app (attached when the subtitle
/// is written into the video), installed on the Mac, or missing.
extension WorkspaceModel {
    /// Where the video's attached fonts are extracted for the preview.
    var embeddedFontsDirectory: URL { app.paths.caches.appendingPathComponent("Fonts/\(project.id)", isDirectory: true) }

    var addedFontFiles: [URL] { store.addedFontURLs(for: project) }

    func fontStatuses() -> [FontStatus] {
        let attached = Self.families(in: files(in: embeddedFontsDirectory))
        let added = Self.families(in: addedFontFiles)
        let installed = Set(NSFontManager.shared.availableFontFamilies.map { $0.lowercased() })
        return editor.usedFonts.map { family in
            let key = family.lowercased()
            // ASS names a font by family (“Open Sans”) or full name (“Open Sans Semibold”).
            let onMac = installed.contains(key) || NSFont(name: family, size: 12) != nil
            let source: FontStatus.Source = attached.contains(key) ? .attached : added.contains(key) ? .added
                : onMac ? .installed : .missing
            return FontStatus(family: family, source: source)
        }
    }

    /// Fonts the person can pick for a style: the Mac's, the video's and the added ones.
    var availableFontFamilies: [String] {
        let extra = Self.familyNames(in: files(in: embeddedFontsDirectory) + addedFontFiles)
        return Array(Set(NSFontManager.shared.availableFontFamilies + extra)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func addFonts() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["ttf", "otf", "ttc"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Escolha as fontes. Elas serão anexadas ao vídeo quando você gravar a legenda.")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let folder = store.fontsDirectory(for: project)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var names = project.addedFonts ?? []
            for url in panel.urls {
                let target = folder.appendingPathComponent(url.lastPathComponent)
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.copyItem(at: url, to: target)
                if !names.contains(url.lastPathComponent) { names.append(url.lastPathComponent) }
            }
            project.addedFonts = names
            project.draftPending = true
            try store.save(project)
            Task { await loadAddedFonts() }
            notice = (.success, String(localized: "\(Plural.count(panel.urls.count, "fonte adicionada", "fontes adicionadas")). Ela vai junto com a legenda em “Gravar no vídeo…”."))
        } catch {
            app.report(error, context: String(localized: "A fonte não foi adicionada"))
        }
    }

    func removeAddedFont(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
        project.addedFonts = (project.addedFonts ?? []).filter { $0 != file.lastPathComponent }
        try? store.save(project)
    }

    /// Saves the video's attached fonts to a folder the person picks.
    func extractFonts() {
        guard let info, !info.attachments.isEmpty, !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Extrair aqui")
        panel.message = String(localized: "Pasta onde salvar as \(Plural.count(info.attachments.filter(\.isFont).count, "fonte", "fontes")) do vídeo")
        panel.directoryURL = url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let folder = panel.url, let mkvextract = app.tools.locate(.mkvextract), claim(String(localized: "Extração de fontes")) else { return }
        let fonts = info.attachments.filter(\.isFont)
        operation = RunningOperation(kind: .extracting, fraction: nil, message: String(localized: "Extraindo as fontes…"))
        task = Task {
            do {
                let specs = fonts.map { "\($0.id):\(FileOps.uniqueURL(for: folder.appendingPathComponent($0.fileName)).path)" }
                try await ProcessRunner.runChecked(mkvextract, [info.url.path, "attachments"] + specs, acceptedExitCodes: [0, 1])
                notice = (.success, "\(Plural.count(fonts.count, "fonte extraída", "fontes extraídas")) para \(folder.path).")
                noticeAction = (String(localized: "Mostrar no Finder"), { NSWorkspace.shared.activateFileViewerSelecting([folder]) })
            } catch {
                notice = (.error, LogRedactor.redact(error.localizedDescription))
            }
            release()
            operation = nil
        }
    }

    /// Gives the added fonts to libass, so the preview uses them.
    func loadAddedFonts() async {
        for file in addedFontFiles {
            guard let data = try? Data(contentsOf: file) else { continue }
            await originalRenderer?.addFont(named: file.lastPathComponent, data: data)
            await translationRenderer?.addFont(named: file.lastPathComponent, data: data)
        }
        renderRevision += 1
    }

    private func files(in folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }

    static func familyNames(in files: [URL]) -> [String] {
        files.flatMap { url -> [String] in
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
            return descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }
        }
    }

    /// Every name a font file answers to (family, full name, PostScript name), lowercased.
    static func families(in files: [URL]) -> Set<String> {
        let keys = [kCTFontFamilyNameAttribute, kCTFontDisplayNameAttribute, kCTFontNameAttribute]
        return Set(files.flatMap { url -> [String] in
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] ?? []
            return descriptors.flatMap { d in keys.compactMap { CTFontDescriptorCopyAttribute(d, $0) as? String } }
        }.map { $0.lowercased() })
    }
}
