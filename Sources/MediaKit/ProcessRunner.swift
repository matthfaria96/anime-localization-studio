import Foundation

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: String

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
}

public enum ProcessError: Error, LocalizedError, Equatable {
    case launchFailed(tool: String, reason: String)
    case failed(tool: String, exitCode: Int32, message: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let tool, let reason): "Não foi possível iniciar \(tool): \(reason)"
        case .failed(let tool, let code, let message):
            message.isEmpty ? "\(tool) terminou com erro (código \(code))." : "\(tool) terminou com erro (código \(code)): \(message)"
        case .cancelled: "Operação cancelada."
        }
    }
}

/// Runs command-line tools without a shell (arguments are passed as-is, so file names with
/// spaces, quotes or `$` are safe), streams output lines for progress, and stops the process
/// when the calling task is cancelled.
public enum ProcessRunner {
    public enum LineSource: Sendable { case stdout, stderr }

    public static func run(
        _ executable: URL,
        _ arguments: [String],
        lineSource: LineSource = .stdout,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let out = OutputCollector(onLine: lineSource == .stdout ? onLine : nil)
        let err = OutputCollector(onLine: lineSource == .stderr ? onLine : nil)
        outPipe.fileHandleForReading.readabilityHandler = { out.append($0.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { err.append($0.availableData) }

        let tool = executable.lastPathComponent
        let box = ProcessBox(process)
        let exitCode: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { finished in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    out.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                    err.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                    out.finish()
                    err.finish()
                    continuation.resume(returning: finished.terminationStatus)
                }
                do {
                    try box.launch()
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: ProcessError.launchFailed(tool: tool, reason: error.localizedDescription))
                }
            }
        } onCancel: {
            box.terminate()
        }
        if Task.isCancelled || box.wasTerminated { throw ProcessError.cancelled }
        return ProcessResult(exitCode: exitCode, stdout: out.data, stderr: String(decoding: err.data, as: UTF8.self))
    }

    /// Runs and throws unless the exit code is in `acceptedExitCodes`.
    @discardableResult
    public static func runChecked(
        _ executable: URL,
        _ arguments: [String],
        acceptedExitCodes: Set<Int32> = [0],
        lineSource: LineSource = .stdout,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let result = try await run(executable, arguments, lineSource: lineSource, onLine: onLine)
        guard acceptedExitCodes.contains(result.exitCode) else {
            let message = lastMeaningfulLines(result.stderr.isEmpty ? result.stdoutText : result.stderr)
            throw ProcessError.failed(tool: executable.lastPathComponent, exitCode: result.exitCode, message: message)
        }
        return result
    }

    static func lastMeaningfulLines(_ text: String, count: Int = 3) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#GUI#progress") }
            .suffix(count)
            .joined(separator: " ")
    }
}

/// Lets the cancellation handler reach the process from another thread.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var terminated = false

    init(_ process: Process) { self.process = process }

    var wasTerminated: Bool { lock.withLock { terminated } }

    /// Launches unless cancellation already arrived; under the same lock as `terminate()`, so a
    /// cancel between the caller's check and the launch can never be missed.
    func launch() throws {
        try lock.withLock {
            try process.run()
            if terminated { process.terminate() }
        }
    }

    func terminate() {
        lock.withLock {
            terminated = true
            if process.isRunning { process.terminate() }
        }
    }
}

/// Collects a pipe's bytes and, optionally, reports complete lines (`\n` or `\r` terminated,
/// which covers FFmpeg's carriage-return progress) as they arrive.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var pending = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    var data: Data { lock.withLock { buffer } }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        var lines: [String] = []
        lock.withLock {
            buffer.append(chunk)
            guard onLine != nil else { return }
            pending.append(chunk)
            while let end = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = pending[pending.startIndex..<end]
                if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
                pending.removeSubrange(pending.startIndex...end)
            }
        }
        lines.forEach { onLine?($0) }
    }

    func finish() {
        let rest: String? = lock.withLock {
            defer { pending.removeAll() }
            return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
        }
        if let rest { onLine?(rest) }
    }
}
