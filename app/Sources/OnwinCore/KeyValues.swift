import Foundation

/// Valve's KeyValues text format (VDF), used by Steam for `libraryfolders.vdf`, `appmanifest_*.acf`,
/// `config.vdf`, `loginusers.vdf`...:
///
///     "AppState"
///     {
///         "appid"      "570"
///         "name"       "Dota 2"
///         "UserConfig" { "language" "russian" }
///     }
///
/// Tokens are quoted strings (escapes `\"`, `\\`, `\n`, `\t`) or bare words, `{` / `}` open and close
/// a section, `//` starts a comment, `[$WIN32]`-style conditions after a token are ignored, and
/// `#include` / `#base` directives are skipped. Keys are case-insensitive, as in Valve's own reader;
/// duplicate keys are kept in order (the first one wins on lookup).
public indirect enum KeyValues: Hashable, Sendable {
    case string(String)
    case section([Entry])

    public struct Entry: Hashable, Sendable {
        public var key: String
        public var value: KeyValues
        public init(key: String, value: KeyValues) { self.key = key; self.value = value }
    }

    // MARK: Access

    /// Value of a child key (case-insensitive), nil when absent or when this is a string.
    public subscript(key: String) -> KeyValues? {
        guard case .section(let entries) = self else { return nil }
        return entries.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    /// Follows a path of keys: `kv[path: "AppState", "UserConfig", "language"]`.
    public subscript(path keys: String...) -> KeyValues? {
        var node: KeyValues? = self
        for key in keys { node = node?[key] }
        return node
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var int: Int? { string.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }

    public var entries: [Entry] {
        if case .section(let e) = self { return e }
        return []
    }

    // MARK: Parsing

    public struct ParseError: Error, LocalizedError, Sendable {
        public var message: String
        public var line: Int
        public var errorDescription: String? { "VDF, строка \(line): \(message)" }
    }

    /// Parses a whole file. The result is a section holding the top-level entries
    /// (usually exactly one, e.g. "AppState" or "libraryfolders").
    public static func parse(_ text: String) throws -> KeyValues {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        return .section(try parser.parseEntries(topLevel: true))
    }

    public static func parse(contentsOf url: URL) throws -> KeyValues {
        let data = try Data(contentsOf: url)
        // Steam writes UTF-8; very old files may be in the system code page.
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return try parse(text)
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var index = 0
        var line = 1

        init(scalars: [Unicode.Scalar]) {
            self.scalars = scalars
            // Byte order mark.
            if scalars.first == "\u{FEFF}" { index = 1 }
        }

        enum Token: Equatable { case text(String), open, close, end }

        mutating func error(_ message: String) -> ParseError { ParseError(message: message, line: line) }

        mutating func skipWhitespaceAndComments() {
            while index < scalars.count {
                let c = scalars[index]
                if c == "\n" { line += 1; index += 1; continue }
                if c == " " || c == "\t" || c == "\r" || c == "\u{FEFF}" { index += 1; continue }
                if c == "/", index + 1 < scalars.count, scalars[index + 1] == "/" {
                    while index < scalars.count, scalars[index] != "\n" { index += 1 }
                    continue
                }
                break
            }
        }

        mutating func next() throws -> Token {
            skipWhitespaceAndComments()
            guard index < scalars.count else { return .end }
            let c = scalars[index]
            switch c {
            case "{": index += 1; return .open
            case "}": index += 1; return .close
            case "\"":
                index += 1
                var s = String.UnicodeScalarView()
                while true {
                    guard index < scalars.count else { throw error("строка в кавычках не закрыта") }
                    let ch = scalars[index]
                    index += 1
                    if ch == "\"" { break }
                    if ch == "\n" { line += 1 }
                    if ch == "\\", index < scalars.count {
                        let e = scalars[index]
                        index += 1
                        switch e {
                        case "n": s.append("\n")
                        case "t": s.append("\t")
                        case "\\": s.append("\\")
                        case "\"": s.append("\"")
                        default: s.append("\\"); s.append(e)
                        }
                        continue
                    }
                    s.append(ch)
                }
                return .text(String(s))
            default:
                var s = String.UnicodeScalarView()
                while index < scalars.count {
                    let ch = scalars[index]
                    if ch == " " || ch == "\t" || ch == "\r" || ch == "\n" || ch == "{" || ch == "}" || ch == "\"" { break }
                    s.append(ch)
                    index += 1
                }
                return .text(String(s))
            }
        }

        /// Skips a `[$WIN32]` / `[!$X360]` condition that may follow a key or a value.
        mutating func skipCondition() {
            let save = (index, line)
            skipWhitespaceAndComments()
            if index < scalars.count, scalars[index] == "[" {
                while index < scalars.count, scalars[index] != "]", scalars[index] != "\n" { index += 1 }
                if index < scalars.count, scalars[index] == "]" { index += 1; return }
            }
            (index, line) = save
        }

        mutating func parseEntries(topLevel: Bool) throws -> [Entry] {
            var entries: [Entry] = []
            while true {
                let token = try next()
                switch token {
                case .end:
                    if topLevel { return entries }
                    throw error("не хватает «}»")
                case .close:
                    if topLevel { throw error("лишняя «}»") }
                    return entries
                case .open:
                    throw error("«{» без имени раздела")
                case .text(let key):
                    if topLevel, key.hasPrefix("#") {
                        // #include "file.vdf" / #base "file.vdf"
                        _ = try next()
                        continue
                    }
                    skipCondition()
                    switch try next() {
                    case .open:
                        entries.append(Entry(key: key, value: .section(try parseEntries(topLevel: false))))
                    case .text(let value):
                        entries.append(Entry(key: key, value: .string(value)))
                    case .close, .end:
                        throw error("у ключа «\(key)» нет значения")
                    }
                    skipCondition()
                }
            }
        }
    }
}
