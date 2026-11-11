import Foundation

/// Small helper around Foundation.Process.
public enum ProcessRunner {
    public struct Result: Sendable {
        public let status: Int32
        public let output: String
    }

    /// Runs a program to completion and returns its exit status and combined stdout+stderr.
    public static func run(_ executable: URL,
                           arguments: [String],
                           environment: [String: String]? = nil,
                           currentDirectory: URL? = nil,
                           onOutput: (@Sendable (String) -> Void)? = nil) async throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let collector = OutputCollector()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            collector.append(data)
            if let onOutput, let text = String(data: data, encoding: .utf8) { onOutput(text) }
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { p in
                // Do not readToEnd(): wineserver and Wine's system processes inherit stderr when
                // they daemonize and keep the pipe open long after the command itself exited.
                // Give the readability handler a moment to drain what is buffered, then stop.
                let status = p.terminationStatus
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: Result(status: status, output: collector.text))
                }
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}

final class OutputCollector: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
