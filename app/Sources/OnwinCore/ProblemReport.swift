import Foundation
import Darwin

/// «Сообщить о проблеме»: a plain-text summary of the Mac, the engine, the space and the last run log
/// that a user can paste into the support chat. Used by the app's report sheet and `onwinctl report`.
///
/// Privacy: the whole text goes through `ProblemReport.redact` — the home folder becomes `~`, the
/// macOS user name, full name and computer name are replaced, and e-mail addresses, Steam IDs, tokens,
/// passwords and similar `key=value` pairs are hidden. Only file *names* of programs are included.
public struct ProblemReport: Sendable {
    /// What to describe; every part is optional (the Help menu has no space or program).
    public struct Subject: Sendable {
        public var space: Space?
        /// Run log to attach (`~/Library/Logs/onwin/<space>/<date> <title>.log`).
        public var logURL: URL?
        /// Program the problem is about (only its file name is used).
        public var programFile: String?
        /// Error message onwin showed, if any.
        public var errorMessage: String?
        /// Exit code of the run, when onwin saw the program exit.
        public var exitStatus: Int32?

        public init(space: Space? = nil, logURL: URL? = nil, programFile: String? = nil, errorMessage: String? = nil,
                    exitStatus: Int32? = nil) {
            self.space = space
            self.logURL = logURL
            self.programFile = programFile
            self.errorMessage = errorMessage
            self.exitStatus = exitStatus
        }
    }

    /// Number of log lines attached from the end of the run log.
    public static let logLineLimit = 200

    // MARK: Building

    /// Collects the diagnostics. Reads files and may run `arch` (Rosetta check): call off the main thread.
    public static func build(_ subject: Subject, userText: String = "", includeLog: Bool = true,
                             logLines: Int = logLineLimit) -> String {
        var out: [String] = []
        func section(_ title: String) {
            if !out.isEmpty { out.append("") }
            out.append("== \(title) ==")
        }
        func line(_ label: String, _ value: String) { out.append("\(label): \(value)") }
        let on = String(localized: "вкл", bundle: .onwinCore, comment: "Problem report: a setting is on")
        let off = String(localized: "выкл", bundle: .onwinCore, comment: "Problem report: a setting is off")

        out.append(L("Отчёт о проблеме onwin — \(dateFormatter.string(from: Date()))"))

        let text = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        section(L("Что случилось"))
        out.append(text.isEmpty ? L("(не описано)") : text)
        if let message = subject.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            line(L("Сообщение onwin"), message)
        }

        // onwin
        section("onwin")
        line(L("Версия"), OnwinVersion.string)
        line(L("Сборка"), bundleBuild ?? L("нет (запущено не из Onwin.app)"))

        // Mac
        section("Mac")
        line("macOS", HostSupport.macOSVersion)
        line(L("Модель"), sysctlString("hw.model") ?? L("неизвестно"))
        line(L("Процессор"), sysctlString("machdep.cpu.brand_string") ?? (HostSupport.isAppleSilicon ? "Apple Silicon" : "Intel"))
        if let gpu = HostSupport.gpuName { line(L("Видеокарта"), gpu) }
        line(L("Память"), ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory))
        line("Rosetta 2", !HostSupport.isAppleSilicon ? L("не нужна (Intel)")
             : HostSupport.isRosettaInstalled() ? L("установлена") : L("НЕ установлена"))

        // Engine and graphics
        section(L("Движок"))
        let engine = try? EngineManager.engine(for: subject.space?.config)
        if let engine {
            line(L("Движок"), "\(engine.info.displayName) [\(engine.id)]")
            line("Wine", engine.info.wineVersion)
            if let cx = engine.info.crossoverSourceVersion { line(L("Исходники CodeWeavers"), cx) }
            line(L("Состав"), [engine.hasDXMT ? "DXMT" : nil, engine.hasDXVK ? "DXVK" : nil,
                               engine.hasMoltenVK ? "MoltenVK" : nil,
                               engine.hasBundledAddons ? "Wine Mono/Gecko" : nil].compactMap { $0 }.joined(separator: ", "))
        } else {
            line(L("Движок"), L("не установлен"))
        }
        line("D3DMetal", GraphicsSupport.isD3DMetalInstalled ? L("установлен") : L("не установлен"))
        let otherEngines = EngineManager.installedEngines().map(\.id).filter { $0 != engine?.id }
        if !otherEngines.isEmpty { line(L("Другие движки"), otherEngines.joined(separator: ", ")) }

        // Space
        if let space = subject.space {
            let config = space.config
            section(L("Пространство"))
            line(L("Имя"), space.name)
            line(L("Версия Windows"), config.windowsVersion.displayName)
            var graphics = config.graphicsBackend.displayName
            if let engine {
                let resolved = GraphicsSupport.resolve(config.graphicsBackend, engine: engine)
                if resolved != config.graphicsBackend { graphics += " → \(resolved.displayName)" }
            }
            line(L("Графика"), graphics)
            line("MSync", config.msync ? on : off)
            line("Retina", config.highResolution ? on : off)
            line(L("AVX для игр"), config.advertiseAVX ? on : off)
            if config.metalHUD { line("Metal HUD", on) }
            if config.dxrRaytracing { line("DXR", on) }
            if config.metalFX { line("DLSS → MetalFX", on) }
            line(L("Подробный журнал"), config.debugLogging ? L("вкл (\(config.wineDebugChannels))") : off)
            let components = config.installedComponents.map { id in Catalog.component(id).map { "\($0.name) [\(id)]" } ?? id }
            let none = String(localized: "нет", bundle: .onwinCore, comment: "Problem report: no components")
            line(L("Компоненты"), components.isEmpty ? none : components.joined(separator: ", "))
            if !config.dllOverrides.isEmpty {
                let disabled = String(localized: "откл", bundle: .onwinCore, comment: "Problem report: DLL override that disables the library")
                line(L("Замены DLL"), config.dllOverrides.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value.isEmpty ? disabled : $0.value)" }.joined(separator: ", "))
            }
            // Only variable names: values may hold paths or keys.
            if !config.environment.isEmpty {
                line(L("Свои переменные"), config.environment.keys.sorted().joined(separator: ", "))
            }
            let yes = String(localized: "да", bundle: .onwinCore, comment: "Problem report: yes")
            line(L("Подготовлено"), space.isInitialized ? yes : L("нет (wineboot не выполнялся)"))
        }

        // Program and log
        let log = subject.logURL.map { readLog($0, lines: logLines) }
        let program = subject.programFile.map { fileName(of: $0) } ?? log?.programFile
        if program != nil || log != nil {
            section(L("Программа"))
            if let program { line(L("Файл"), program) }
            if let date = log?.modified { line(L("Последняя запись в журнал"), dateFormatter.string(from: date)) }
            if let status = subject.exitStatus { line(L("Код завершения"), "\(status)") }
        }

        if includeLog {
            section(L("Журнал запуска"))
            if let log {
                if let error = log.error {
                    out.append(L("(не удалось прочитать: \(error))"))
                } else {
                    if !log.header.isEmpty {
                        out.append(contentsOf: log.header)
                        out.append("…")
                    }
                    if log.truncated { out.append(L("(последние \(log.body.count) строк из журнала)")) }
                    out.append(contentsOf: log.body.isEmpty ? [L("(пусто)")] : log.body)
                }
            } else {
                out.append(L("(журнала нет)"))
            }
        }

        return redact(out.joined(separator: "\n")) + "\n"
    }

    // MARK: Logs

    /// Newest run log of `space`; with `program`, the newest one whose title or command mentions that file.
    public static func latestLog(in space: Space, program: String? = nil) -> URL? {
        let files = space.logFiles()
        guard let program, !program.isEmpty else { return files.first }
        let name = fileName(of: program).lowercased()
        let base = (name as NSString).deletingPathExtension
        return files.first { url in
            let title = url.deletingPathExtension().lastPathComponent.lowercased()
            if title.hasSuffix(" " + base) || title == base { return true }
            return readHeader(of: url).contains { $0.lowercased().hasPrefix("command:") && $0.lowercased().contains(name) }
        }
    }

    /// Space whose log folder holds `logURL` (`~/Library/Logs/onwin/<space folder>/…`).
    public static func space(forLog logURL: URL) -> Space? {
        let folder = logURL.deletingLastPathComponent().lastPathComponent
        return SpaceManager.list().first { SpaceManager.directoryName(for: $0.name).caseInsensitiveCompare(folder) == .orderedSame }
    }

    struct LogExcerpt {
        var header: [String] = []
        var body: [String] = []
        var truncated = false
        var programFile: String?
        var modified: Date?
        var error: String?
    }

    static let headerSeparator = "----------------------------------------------------------------"

    /// The header WineRunner.launch writes (up to the dashed line), or nothing for other files.
    static func readHeader(of url: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 8192)) ?? Data()
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        guard let end = lines.prefix(20).firstIndex(of: headerSeparator) else { return [] }
        return Array(lines[..<end])
    }

    static func readLog(_ url: URL, lines limit: Int) -> LogExcerpt {
        var excerpt = LogExcerpt()
        excerpt.modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let header = readHeader(of: url)
        // The env: line repeats every Wine variable; the settings above say the same in plain words.
        excerpt.header = header.filter { !$0.hasPrefix("env:") }
        if let command = header.first(where: { $0.hasPrefix("command:") }) {
            excerpt.programFile = programFile(inCommand: command)
        }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            // 200 lines of Wine output rarely exceed a few dozen KB; 512 KB is plenty and stays fast.
            let window: UInt64 = 512 * 1024
            let start = size > window ? size - window : 0
            try handle.seek(toOffset: start)
            let data = try handle.readToEnd() ?? Data()
            var all = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            if start > 0, !all.isEmpty { all.removeFirst() }   // a partial line
            if start == 0, let sep = all.firstIndex(of: headerSeparator), sep < 20 {
                all.removeSubrange(...sep)                       // the header is shown separately
            }
            while let last = all.last, last.trimmingCharacters(in: .whitespaces).isEmpty { all.removeLast() }
            excerpt.truncated = start > 0 || all.count > limit
            excerpt.body = Array(all.suffix(limit))
        } catch {
            excerpt.error = error.localizedDescription
        }
        return excerpt
    }

    /// "command: wine /Users/x/Games/My Game/game.exe -windowed" → "game.exe".
    public static func programFile(inCommand command: String) -> String? {
        let pattern = #"([^/\\:"]+\.(?:exe|msi|bat|cmd|lnk|com|scr))(?=$|[\s"])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = command as NSString
        let matches = regex.matches(in: command, range: NSRange(location: 0, length: ns.length))
        // The first runnable file after "wine" is the program (msiexec / start come without an extension).
        guard let match = matches.first else { return nil }
        // The match starts after the last '/' or '\\' (or after "command:" when there is no path),
        // so a file name with spaces stays whole.
        var name = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
        if name.lowercased().hasPrefix("wine ") { name = String(name.dropFirst(5)) }
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// File name only, for both Unix and Windows paths.
    static func fileName(of path: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        return (normalized as NSString).lastPathComponent
    }

    // MARK: Redaction

    /// Hides personal data: home folder → `~`, user / computer names → `<пользователь>` / `<компьютер>`,
    /// e-mail addresses, Steam IDs, tokens, passwords, keys.
    public static func redact(_ text: String) -> String {
        redact(text, identity: .current)
    }

    struct Identity {
        var home: String
        var userName: String
        var fullName: String
        var computerNames: [String]

        static var current: Identity {
            var names: [String] = []
            var buffer = [CChar](repeating: 0, count: 256)
            if gethostname(&buffer, buffer.count) == 0 {
                let host = String(cString: buffer)
                names.append(host)
                if let short = host.split(separator: ".").first { names.append(String(short)) }
            }
            return Identity(home: NSHomeDirectory(), userName: NSUserName(), fullName: NSFullUserName(),
                            computerNames: names)
        }
    }

    static func redact(_ text: String, identity: Identity) -> String {
        var s = text
        let hidden = NSRegularExpression.escapedTemplate(for: L("<скрыто>"))

        // 1. Home folder, as a Unix path and as Wine shows it (Z:\Users\name, with either slash).
        var homes = [identity.home]
        let resolved = (identity.home as NSString).resolvingSymlinksInPath
        if resolved != identity.home { homes.append(resolved) }
        for home in homes where home.count > 1 {
            // Z: forms first, otherwise "Z:/Users/name" would become "Z:~".
            let windows = "Z:" + home.replacingOccurrences(of: "/", with: "\\")
            s = replace(s, NSRegularExpression.escapedPattern(for: windows), with: "~", caseInsensitive: true)
            let windowsSlash = "Z:" + home
            s = replace(s, NSRegularExpression.escapedPattern(for: windowsSlash), with: "~", caseInsensitive: true)
            s = replace(s, NSRegularExpression.escapedPattern(for: home) + #"(?=$|[/\\\s"'):;,])"#, with: "~")
        }

        // 2. User, full and computer names as whole words (Wine's C:\users\<name>, host names in logs).
        //    Computer names first: they often contain the user's name ("Dianas-MacBook-Pro").
        let computer = NSRegularExpression.escapedTemplate(for: L("<компьютер>"))
        let user = NSRegularExpression.escapedTemplate(for: L("<пользователь>"))
        let names: [(String, String)] = identity.computerNames.map { ($0, computer) }
            + [(identity.fullName, user), (identity.userName, user)]
        for (name, replacement) in names.sorted(by: { $0.0.count > $1.0.count }) where name.count >= 2 {
            s = replace(s, #"(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: name) + #"(?![\p{L}\p{N}_])"#,
                        with: replacement, caseInsensitive: true)
        }

        // 3. E-mail addresses.
        s = replace(s, #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, with: "<e-mail>")

        // 4. Steam: 64-bit SteamIDs (7656119…), steamid=…, account names.
        s = replace(s, #"\b7656119\d{10}\b"#, with: "<steamid>")
        s = replace(s, #"(?i)(steam_?id(?:64)?|account_?id|account_?name|accountname|persona_?name|login|user_?name)(\s*[=:]\s*"?|"\s+")[^\s"&;,]+"#,
                    with: "$1$2" + hidden)

        // 5. Tokens, passwords, keys: key=value / key: value / "key" "value", also in URL query strings.
        s = replace(s, #"(?i)\bBearer\s+[A-Za-z0-9._~+/\-]+=*"#, with: hidden)
        s = replace(s, #"(?i)\b([\w.\-]*?(?:token|password|passwd|pwd|secret|api_?key|access_?key|auth|authorization|cookie|session_?id|sessionid|ticket|signature))\b(\s*[=:]\s*"?|"\s+")[^\s"&;,]+"#,
                    with: "$1$2" + hidden)
        // JSON Web Tokens.
        s = replace(s, #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#,
                    with: NSRegularExpression.escapedTemplate(for: L("<токен>")))


        return s
    }

    private static func replace(_ s: String, _ pattern: String, with template: String, caseInsensitive: Bool = false) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else {
            return s
        }
        return regex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                              withTemplate: template)
    }

    // MARK: Helpers

    /// OnwinCore lookup for the report's labels and values (literals passed here are extracted as keys).
    private static func L(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .onwinCore)
    }

    private static var bundleBuild: String? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        let info = Bundle.main.infoDictionary
        let build = info?["CFBundleVersion"] as? String
        let short = info?["CFBundleShortVersionString"] as? String
        switch (short, build) {
        case let (s?, b?) where s != b: return "\(s) (\(b))"
        case let (_, b?): return b
        case let (s?, nil): return s
        default: return nil
        }
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return f
    }()
}
