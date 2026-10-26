import Foundation
import os

/// Removes secrets and personal paths before anything reaches a log file or the UI.
public enum LogRedactor {
    private static let rules: [(NSRegularExpression, String)] = [
        (#"(?i)bearer\s+[A-Za-z0-9._\-]+"#, "Bearer ‹oculto›"),
        (#"\b(?:sk|sk-proj|sk-ant|hf|gsk|xai)[-_][A-Za-z0-9_\-]{12,}"#, "‹chave oculta›"),
        (#"(?i)(api[_-]?key|token|password|secret)(["']?\s*[:=]\s*["']?)[^\s"'&,}]+"#, "$1$2‹oculto›")
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    public static func redact(_ text: String) -> String {
        var output = text
        for (regex, template) in rules {
            output = regex.stringByReplacingMatches(in: output, range: NSRange(output.startIndex..., in: output), withTemplate: template)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return output.replacingOccurrences(of: home, with: "~")
    }
}

/// Unified logging (Console.app, subsystem `com.witchmymac.animelocalizationstudio`) plus a
/// daily text file under Application Support › Logs for diagnostics bundles.
public final class AppLog: Sendable {
    public static let shared = AppLog(directory: AppPaths().logs)

    private let logger = Logger(subsystem: "com.witchmymac.animelocalizationstudio", category: "app")
    private let directory: URL
    private let queue = DispatchQueue(label: "AppLog.file")

    public init(directory: URL) { self.directory = directory }

    public func info(_ message: String) { write("INFO", message) }
    public func error(_ message: String) { write("ERRO", message) }

    public var currentFile: URL {
        let day = Date().formatted(.iso8601.year().month().day())
        return directory.appendingPathComponent("\(day).log")
    }

    private func write(_ level: String, _ message: String) {
        let clean = LogRedactor.redact(message)
        if level == "ERRO" { logger.error("\(clean, privacy: .public)") } else { logger.info("\(clean, privacy: .public)") }
        let line = "\(Date().formatted(.iso8601)) [\(level)] \(clean)\n"
        let url = currentFile
        let directory = directory
        queue.async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
