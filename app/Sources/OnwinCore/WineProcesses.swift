import Foundation

/// What Wine processes really run, independent of what onwin started itself.
///
/// Wine sets each process's argv to its Windows command line, so `ps` shows e.g.
/// `C:\Program Files (x86)\Steam\steamapps\common\Rusty Lake Hotel\RustyLakeHotel.exe`. (Wine reuses the
/// argv/environment memory for that, so `ps -E` cannot show WINEPREFIX for these processes.)
/// Used for Steam games: Steam starts them, not onwin, so onwin's own process tracking cannot tell when
/// the game itself exits.
public enum WineProcesses {
    public struct Entry: Sendable, Hashable {
        public var pid: Int32
        /// Lowercased command line with '/' turned into '\'.
        public var command: String
    }

    /// All processes whose command line looks like a Windows one ("X:\...").
    public static func snapshot() async -> [Entry] {
        guard let result = try? await ProcessRunner.run(URL(fileURLWithPath: "/bin/ps"),
                                                        arguments: ["-axww", "-o", "pid=,command="]) else { return [] }
        var out: [Entry] = []
        for line in result.output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            let parts = text.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            let command = String(parts[1])
            guard command.count > 3, command.dropFirst().hasPrefix(":\\") else { continue }
            out.append(Entry(pid: pid, command: command.replacingOccurrences(of: "/", with: "\\").lowercased()))
        }
        return out
    }

    /// Processes of this Steam game (anything started from its install directory).
    public static func processes(of game: SteamGame, in entries: [Entry]) -> [Entry] {
        let folder = "\\steamapps\\common\\" + game.installDirectory.lastPathComponent.lowercased() + "\\"
        return entries.filter { $0.command.contains(folder) }
    }

    /// The Unix working directory of a process (`lsof -d cwd`), used to tell spaces apart when the same
    /// game is installed in several of them.
    public static func workingDirectory(of pid: Int32) async -> String? {
        guard let r = try? await ProcessRunner.run(URL(fileURLWithPath: "/usr/sbin/lsof"),
                                                   arguments: ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]) else { return nil }
        return r.output.split(separator: "\n").first { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
    }
}
