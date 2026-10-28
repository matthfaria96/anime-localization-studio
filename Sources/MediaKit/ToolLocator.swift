import Foundation

public enum ExternalTool: String, CaseIterable, Sendable, Codable, Identifiable {
    case mkvmerge, mkvextract, mkvpropedit, ffmpeg, ffprobe

    public var id: String { rawValue }

    public var package: String {
        switch self {
        case .mkvmerge, .mkvextract, .mkvpropedit: "MKVToolNix"
        case .ffmpeg, .ffprobe: "FFmpeg"
        }
    }

    public var purpose: String {
        switch self {
        case .mkvmerge: String(localized: "Ler o MKV e gravar faixas nele sem recodificar")
        case .mkvextract: String(localized: "Extrair legendas e áudio do MKV sem perdas")
        case .mkvpropedit: String(localized: "Trocar faixa padrão e nomes no próprio MKV, sem regravar")
        case .ffmpeg: String(localized: "Pré-visualização, extração de áudio e verificação de quadros")
        case .ffprobe: String(localized: "Inspecionar arquivos que não são Matroska")
        }
    }

    public var installCommand: String {
        switch self {
        case .mkvmerge, .mkvextract, .mkvpropedit: "brew install mkvtoolnix"
        case .ffmpeg, .ffprobe: "brew install ffmpeg"
        }
    }

    var versionArguments: [String] {
        switch self {
        case .mkvmerge, .mkvextract, .mkvpropedit: ["--version"]
        case .ffmpeg, .ffprobe: ["-hide_banner", "-version"]
        }
    }
}

public struct ToolStatus: Sendable, Hashable, Identifiable {
    public let tool: ExternalTool
    public let url: URL?
    public let version: String?
    public let problem: String?

    public var id: ExternalTool { tool }
    public var isAvailable: Bool { url != nil && problem == nil }
}

public enum ToolError: Error, LocalizedError, Equatable {
    case missing(ExternalTool)

    public var errorDescription: String? {
        switch self {
        case .missing(let tool):
            String(localized: "\(tool.rawValue) (\(tool.package)) não foi encontrado. Instale com “\(tool.installCommand)” ou indique o caminho em Ajustes › Ferramentas.")
        }
    }
}

/// Finds external tools. Apps opened from Finder do not inherit the shell's PATH, so the usual
/// install locations (Homebrew on Apple silicon and Intel, MacPorts, the MKVToolNix app bundle)
/// are searched explicitly. A path chosen in Settings always wins.
public struct ToolLocator: Sendable {
    public var overrides: [ExternalTool: URL]
    public var searchDirectories: [URL]

    public static let defaultSearchDirectories: [URL] = [
        "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"
    ].map { URL(fileURLWithPath: $0, isDirectory: true) }

    public init(overrides: [ExternalTool: URL] = [:], searchDirectories: [URL] = ToolLocator.defaultSearchDirectories) {
        self.overrides = overrides
        self.searchDirectories = searchDirectories
    }

    public func locate(_ tool: ExternalTool) -> URL? {
        let fm = FileManager.default
        if let url = overrides[tool] { return fm.isExecutableFile(atPath: url.path) ? url : nil }
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: tool.rawValue), fm.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        for directory in searchDirectories + Self.mkvToolNixAppDirectories() {
            let candidate = directory.appendingPathComponent(tool.rawValue)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    public func require(_ tool: ExternalTool) throws -> URL {
        guard let url = locate(tool) else { throw ToolError.missing(tool) }
        return url
    }

    public func status(of tool: ExternalTool) async -> ToolStatus {
        guard let url = locate(tool) else { return ToolStatus(tool: tool, url: nil, version: nil, problem: String(localized: "Não encontrado")) }
        do {
            let result = try await ProcessRunner.run(url, tool.versionArguments)
            let first = result.stdoutText.split(whereSeparator: \.isNewline).first.map(String.init)
            guard result.exitCode == 0, let first else {
                return ToolStatus(tool: tool, url: url, version: nil, problem: String(localized: "Não respondeu a \(tool.versionArguments.joined(separator: " "))"))
            }
            return ToolStatus(tool: tool, url: url, version: Self.shortVersion(first, tool: tool), problem: nil)
        } catch {
            return ToolStatus(tool: tool, url: url, version: nil, problem: error.localizedDescription)
        }
    }

    public func diagnose() async -> [ToolStatus] {
        await withTaskGroup(of: ToolStatus.self) { group in
            for tool in ExternalTool.allCases { group.addTask { await status(of: tool) } }
            var results: [ToolStatus] = []
            for await status in group { results.append(status) }
            return results.sorted { ExternalTool.allCases.firstIndex(of: $0.tool)! < ExternalTool.allCases.firstIndex(of: $1.tool)! }
        }
    }

    static func shortVersion(_ line: String, tool: ExternalTool) -> String {
        // "mkvmerge v103.0 ('The Darkness') 64-bit" → "103.0"; "ffmpeg version 9.0.2 Copyright…" → "9.0.2"
        let words = line.split(separator: " ")
        switch tool {
        case .mkvmerge, .mkvextract, .mkvpropedit:
            return words.first { $0.hasPrefix("v") && $0.dropFirst().first?.isNumber == true }.map { String($0.dropFirst()) } ?? line
        case .ffmpeg, .ffprobe:
            if let i = words.firstIndex(of: "version"), i + 1 < words.count { return String(words[i + 1]) }
            return line
        }
    }

    private static func mkvToolNixAppDirectories() -> [URL] {
        let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: applications.path)) ?? []
        return names.filter { $0.hasPrefix("MKVToolNix") && $0.hasSuffix(".app") }
            .sorted(by: >)
            .map { applications.appendingPathComponent($0).appendingPathComponent("Contents/MacOS", isDirectory: true) }
    }
}
