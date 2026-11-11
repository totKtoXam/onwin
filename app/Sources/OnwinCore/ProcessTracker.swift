import Foundation
import Observation

/// A Windows program started by onwin.
@MainActor
@Observable
public final class RunningProgram: Identifiable {
    public let id = UUID()
    public let spaceID: UUID
    public let spaceName: String
    public let title: String
    public let command: [String]
    public let logURL: URL
    public let started = Date()
    public var pid: Int32 = 0
    public private(set) var exitStatus: Int32?
    public var isRunning: Bool { exitStatus == nil }

    init(spaceID: UUID, spaceName: String, title: String, command: [String], logURL: URL) {
        self.spaceID = spaceID
        self.spaceName = spaceName
        self.title = title
        self.command = command
        self.logURL = logURL
    }

    func finish(status: Int32) {
        exitStatus = status
        ProcessTracker.shared.didFinish(self)
    }
}

/// Keeps the list of programs started from this onwin instance.
@MainActor
@Observable
public final class ProcessTracker {
    public static let shared = ProcessTracker()

    public private(set) var programs: [RunningProgram] = []
    /// Called whenever a program exits (the app uses it to refresh spaces and show errors).
    public var onFinish: ((RunningProgram) -> Void)?

    public var running: [RunningProgram] { programs.filter(\.isRunning) }

    public func running(in spaceID: UUID) -> [RunningProgram] {
        programs.filter { $0.spaceID == spaceID && $0.isRunning }
    }

    func add(_ program: RunningProgram) {
        programs.append(program)
        // Keep the history short.
        let finished = programs.filter { !$0.isRunning }
        if finished.count > 50, let oldest = finished.first {
            programs.removeAll { $0.id == oldest.id }
        }
    }

    func didFinish(_ program: RunningProgram) {
        onFinish?(program)
    }
}
