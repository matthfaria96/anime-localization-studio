import Foundation

public struct VerificationReport: Sendable, Hashable, Codable {
    public struct Check: Sendable, Hashable, Codable, Identifiable {
        public var id: String { title }
        public let title: String
        public let passed: Bool
        public let detail: String
    }

    public var checks: [Check] = []
    public var outputInfo: MediaInfo?

    public var passed: Bool { checks.allSatisfy(\.passed) }
    public var failures: [String] { checks.filter { !$0.passed }.map { "\($0.title): \($0.detail)" } }

    mutating func add(_ title: String, _ passed: Bool, _ detail: String) {
        checks.append(Check(title: title, passed: passed, detail: detail))
    }
}

/// Checks a muxed file before the app reports success: it must open, keep every original track
/// with the same codec, language and dimensions, contain the new tracks with the requested
/// metadata, keep attachments and chapters, last as long as the source, and carry the very same
/// video packets (proof that the video was copied, not re-encoded).
public struct IntegrityVerifier: Sendable {
    public let tools: ToolLocator
    /// Video packets compared between source and output.
    public var packetsToCompare = 240

    public init(tools: ToolLocator) { self.tools = tools }

    public func verifyMux(plan: MuxPlan, output: URL) async throws -> VerificationReport {
        var report = VerificationReport()
        let info: MediaInfo
        do {
            info = try await MediaInspector(tools: tools).inspect(output)
            report.outputInfo = info
            report.add("Arquivo legível", info.isMatroska, info.container)
        } catch {
            report.add("Arquivo legível", false, error.localizedDescription)
            return report
        }

        let expected = plan.keptTracks.count + plan.newTracks.count
        report.add("Número de faixas", info.tracks.count == expected, "\(info.tracks.count) de \(expected) esperadas")

        // Original tracks, matched in order within each kind.
        var missing: [String] = []
        for kind in MediaTrack.Kind.allCases {
            var remaining = info.tracks(kind)
            for original in plan.keptTracks.filter({ $0.kind == kind }) {
                if let match = remaining.firstIndex(where: { Self.sameTrack(original, $0) }) {
                    remaining.remove(at: match)
                } else {
                    missing.append("\(kind.label) \(original.id) (\(original.displayLanguage) \(original.name ?? ""))")
                }
            }
        }
        report.add("Faixas originais preservadas", missing.isEmpty, missing.isEmpty ? "Todas presentes" : "Ausentes: " + missing.joined(separator: ", "))

        for new in plan.newTracks {
            let found = info.tracks(new.kind).first { track in
                (track.languageIETF == new.language || Self.iso6392(for: new.language) == track.language)
                    && (track.name ?? "") == new.name
            }
            let flagsOK = found.map { $0.isDefault == new.isDefault && $0.isForced == new.isForced } ?? false
            report.add("Nova faixa “\(new.name)”", found != nil && flagsOK,
                       found == nil ? "Não encontrada" : flagsOK ? "Idioma \(new.language), \(new.isDefault ? "padrão" : "não padrão")" : "Flags padrão/forçada diferentes do pedido")
        }

        if plan.clearOtherDefaults {
            for kind in Set(plan.newTracks.filter(\.isDefault).map(\.kind)) {
                let defaults = info.tracks(kind).filter(\.isDefault).count
                report.add("Uma faixa padrão de \(kind.label.lowercased())", defaults == 1, "\(defaults) marcadas como padrão")
            }
        }

        let expectedAttachments = plan.source.attachments.count + plan.newAttachments.count
        report.add("Anexos (fontes) preservados", info.attachments.count == expectedAttachments,
                   "\(info.attachments.count) de \(expectedAttachments)")
        for file in plan.newAttachments {
            let found = info.attachments.contains { $0.fileName.caseInsensitiveCompare(file.lastPathComponent) == .orderedSame }
            report.add("Fonte “\(file.lastPathComponent)” anexada", found, found ? "Presente" : "Não encontrada")
        }
        report.add("Capítulos preservados", info.chapterCount == plan.source.chapterCount,
                   "\(info.chapterCount) de \(plan.source.chapterCount)")

        if let a = plan.source.durationMilliseconds, let b = info.durationMilliseconds {
            report.add("Duração", abs(a - b) <= 1_000, "\(b / 1_000) s (original \(a / 1_000) s)")
        }

        if !plan.source.tracks(.video).isEmpty {
            if tools.locate(.ffmpeg) != nil {
                let (same, detail) = try await samePackets(plan.source.url, output)
                report.add("Vídeo sem recodificação", same, detail)
            } else {
                report.add("Vídeo sem recodificação", true, "Comparação de pacotes indisponível sem FFmpeg; codec e resolução conferem.")
            }
        }
        return report
    }

    public static func sameTrack(_ a: MediaTrack, _ b: MediaTrack) -> Bool {
        a.kind == b.kind && a.codecID == b.codecID && a.language == b.language
            && (a.name ?? "") == (b.name ?? "") && a.width == b.width && a.height == b.height
            && a.channels == b.channels && a.sampleRate == b.sampleRate
    }

    /// Compares size and MD5 of the first video packets (`-c copy -f framemd5`), which differ
    /// for any re-encode but are identical after a lossless remux.
    func samePackets(_ a: URL, _ b: URL) async throws -> (Bool, String) {
        let ffmpeg = try tools.require(.ffmpeg)
        async let left = packetHashes(ffmpeg, a)
        async let right = packetHashes(ffmpeg, b)
        let (x, y) = try await (left, right)
        guard !x.isEmpty else { return (false, "Não foi possível ler os pacotes de vídeo do original.") }
        let same = x == y
        return (same, same ? "\(x.count) pacotes idênticos ao original" : "Os pacotes de vídeo diferem do original")
    }

    private func packetHashes(_ ffmpeg: URL, _ url: URL) async throws -> [String] {
        let result = try await ProcessRunner.runChecked(ffmpeg, ["-nostdin", "-v", "error", "-i", url.path, "-map", "0:v:0", "-c", "copy",
                                                                 "-frames:v", "\(packetsToCompare)", "-f", "framemd5", "-"])
        // Lines: stream_index, dts, pts, duration, size, hash. Timestamps may be rescaled by the
        // container, so only size and hash are compared.
        return result.stdoutText.split(whereSeparator: \.isNewline).compactMap { line in
            guard !line.hasPrefix("#") else { return nil }
            let fields = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return fields.count >= 6 ? "\(fields[4]):\(fields[5])" : nil
        }
    }

    /// `pt-BR` → `por`. Covers the languages the app offers as targets and common sources.
    public static func iso6392(for bcp47: String) -> String {
        let base = bcp47.split(separator: "-").first.map(String.init)?.lowercased() ?? bcp47
        let table = ["pt": "por", "en": "eng", "ja": "jpn", "es": "spa", "fr": "fre", "de": "ger", "it": "ita",
                     "zh": "chi", "ko": "kor", "ru": "rus", "ar": "ara", "und": "und"]
        return table[base] ?? base
    }
}
