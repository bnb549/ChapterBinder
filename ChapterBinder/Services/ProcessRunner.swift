import Foundation

struct ProcessResult: Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

/// Runs bundled/system helpers (ffmpeg, ffprobe, cdparanoia) with cancellation
/// and optional line-oriented progress from stdout.
nonisolated enum ProcessRunner {
    final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func append(_ data: Data) {
            lock.lock()
            storage.append(data)
            lock.unlock()
        }

        func stringValue() -> String {
            lock.lock()
            defer { lock.unlock() }
            return String(data: storage, encoding: .utf8) ?? ""
        }
    }

    final class Handle: @unchecked Sendable {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        private let lock = NSLock()
        private var didFinish = false

        func terminate() {
            lock.lock()
            let running = !didFinish && process.isRunning
            lock.unlock()
            if running {
                process.terminate()
            }
        }

        func markFinished() {
            lock.lock()
            didFinish = true
            lock.unlock()
        }
    }

    @discardableResult
    static func run(
        executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil,
        onStdoutLine: (@Sendable (String) -> Void)? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        try Task.checkCancellation()

        let handle = Handle()
        handle.process.executableURL = executable
        handle.process.arguments = arguments
        handle.process.currentDirectoryURL = currentDirectory
        handle.process.standardOutput = handle.stdout
        handle.process.standardError = handle.stderr
        handle.process.standardInput = FileHandle.nullDevice

        let stdoutBox = DataBox()
        let stderrBox = DataBox()

        handle.stdout.fileHandleForReading.readabilityHandler = { file in
            let chunk = file.availableData
            guard !chunk.isEmpty else { return }
            stdoutBox.append(chunk)
            if let onStdoutLine {
                emitLines(from: chunk, to: onStdoutLine)
            }
        }
        handle.stderr.fileHandleForReading.readabilityHandler = { file in
            let chunk = file.availableData
            guard !chunk.isEmpty else { return }
            stderrBox.append(chunk)
            if let onStderrLine {
                emitLines(from: chunk, to: onStderrLine)
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                handle.process.terminationHandler = { proc in
                    handle.markFinished()
                    handle.stdout.fileHandleForReading.readabilityHandler = nil
                    handle.stderr.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(
                        returning: ProcessResult(
                            exitCode: proc.terminationStatus,
                            stdout: stdoutBox.stringValue(),
                            stderr: stderrBox.stringValue()
                        )
                    )
                }
                do {
                    try handle.process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            handle.terminate()
        }
    }

    private static func emitLines(from data: Data, to handler: @escaping @Sendable (String) -> Void) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(whereSeparator: \.isNewline) {
            let s = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { handler(s) }
        }
    }
}
