import Foundation

/// Reader for the registry files of a Wine prefix (`system.reg` = HKEY_LOCAL_MACHINE,
/// `user.reg` = HKEY_CURRENT_USER). Reading them directly is much faster than `wine reg query`
/// and needs no running wineserver. The format is written by `server/registry.c` (`save_subkeys`):
///
///     WINE REGISTRY Version 2
///     ;; All keys relative to REGISTRY\\Machine
///     #arch=win64
///
///     [Software\\Wow6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{…}] 1794343670
///     #time=1dd7154c02ba088
///     "DisplayName"="Wine Mono Runtime"
///     "UninstallString"=str(2):"MsiExec.exe /I{…}"
///     "WindowsInstaller"=dword:00000001
///     @="default value"
///     "Blob"=hex:01,02,\
///       03,04
///
/// Strings are UTF-8 with C escapes (`\\`, `\"`, `\n`, `\x263a`, octal) — `dump_strW` / `parse_strW`
/// in `server/unicode.c`. The 32-bit view of HKLM\Software lives under `Software\\Wow6432Node`.
///
/// wineserver keeps the registry in memory and writes the files periodically and when it exits,
/// so changes made a moment ago by a running program may not be on disk yet.
public enum WineRegistry {
    public enum Value: Hashable, Sendable {
        case string(String)          // REG_SZ
        case expandString(String)    // REG_EXPAND_SZ, str(2):
        case multiString([String])   // REG_MULTI_SZ, str(7): or hex(7):
        case dword(UInt32)
        case qword(UInt64)           // hex(b):
        case binary(type: Int, Data)

        /// Text of string-like values (multi-strings joined with spaces), the number for integers.
        public var text: String? {
            switch self {
            case .string(let s), .expandString(let s): return s
            case .multiString(let list): return list.joined(separator: " ")
            case .dword(let v): return String(v)
            case .qword(let v): return String(v)
            case .binary: return nil
            }
        }

        public var integer: UInt64? {
            switch self {
            case .dword(let v): return UInt64(v)
            case .qword(let v): return v
            case .string(let s): return UInt64(s.trimmingCharacters(in: .whitespaces))
            default: return nil
            }
        }
    }

    public struct Key: Sendable {
        /// Path relative to the hive root, single backslashes: `Software\Microsoft\…\Uninstall\CXHTML`.
        public var path: String
        /// Value names as written; "" is the default value (`@`).
        public var values: [String: Value]

        /// Last path component.
        public var name: String { path.components(separatedBy: "\\").last ?? path }

        /// Case-insensitive value lookup, like the Windows registry.
        public subscript(name: String) -> Value? {
            if let v = values[name] { return v }
            return values.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    /// Keys whose path starts with one of `prefixes` (case-insensitive; empty = every key).
    /// A prefix matches the key itself and its subkeys.
    public static func keys(in file: URL, under prefixes: [String] = []) -> [Key] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        let lowered = prefixes.map { $0.lowercased() }
        func wanted(_ path: String) -> Bool {
            if lowered.isEmpty { return true }
            let p = path.lowercased()
            return lowered.contains { p == $0 || p.hasPrefix($0.hasSuffix("\\") ? $0 : $0 + "\\") }
        }

        var result: [Key] = []
        var current: Key?
        var pending = ""   // a value line continued with a trailing backslash (hex data)

        func flush() { if let c = current { result.append(c) }; current = nil }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = rawLine
            if line.hasSuffix("\r") { line = line.dropLast() }
            if !pending.isEmpty {
                pending += line.trimmingCharacters(in: .whitespaces)
                if pending.hasSuffix("\\") { pending.removeLast(); continue }
                if current != nil { parseValueLine(Substring(pending), into: &current!) }
                pending = ""
                continue
            }
            guard let first = line.first else { continue }
            switch first {
            case "[":
                flush()
                if let path = parseKeyHeader(line.dropFirst()), wanted(path) {
                    current = Key(path: path, values: [:])
                }
            case "\"", "@":
                guard current != nil else { continue }
                if line.hasSuffix("\\") && isHexValue(line) {
                    pending = String(line.dropLast())
                    continue
                }
                parseValueLine(line, into: &current!)
            default:
                continue   // comments (;;), #time=, #arch=, header
            }
        }
        flush()
        return result
    }

    /// One key, or nil.
    public static func key(_ path: String, in file: URL) -> Key? {
        keys(in: file, under: [path]).first { $0.path.caseInsensitiveCompare(path) == .orderedSame }
    }

    /// HKLM (`system.reg`) and HKCU (`user.reg`) files of a space.
    public static func machineHive(of space: Space) -> URL { space.url.appendingPathComponent("system.reg") }
    public static func userHive(of space: Space) -> URL { space.url.appendingPathComponent("user.reg") }

    // MARK: Line parsing

    private static func isHexValue(_ line: Substring) -> Bool {
        // `"name"=hex:` or `"name"=hex(7):` — only these are continued over several lines.
        guard let eq = valueSeparator(in: line) else { return false }
        return line[line.index(after: eq)...].hasPrefix("hex")
    }

    /// Index of the `=` that separates the value name from the data.
    private static func valueSeparator(in line: Substring) -> Substring.Index? {
        if line.first == "@" {
            let i = line.index(after: line.startIndex)
            return i < line.endIndex && line[i] == "=" ? i : nil
        }
        guard line.first == "\"" else { return nil }
        var i = line.index(after: line.startIndex)
        while i < line.endIndex {
            let c = line[i]
            if c == "\\" {
                i = line.index(after: i)
                if i < line.endIndex { i = line.index(after: i) }
                continue
            }
            if c == "\"" {
                let next = line.index(after: i)
                return next < line.endIndex && line[next] == "=" ? next : nil
            }
            i = line.index(after: i)
        }
        return nil
    }

    private static func parseKeyHeader(_ rest: Substring) -> String? {
        // `Software\\Foo\\Bar] 1794343670` — `]` inside the name is escaped as `\]`.
        let (name, consumed) = unescape(rest, until: "]")
        guard consumed else { return nil }
        return name
    }

    private static func parseValueLine(_ line: Substring, into key: inout Key) {
        guard let eq = valueSeparator(in: line) else { return }
        let name: String
        if line.first == "@" {
            name = ""
        } else {
            name = unescape(line[line.index(after: line.startIndex)..<line.index(before: eq)], until: nil).0
        }
        let data = line[line.index(after: eq)...]
        if let value = parseData(data) { key.values[name] = value }
    }

    private static func parseData(_ data: Substring) -> Value? {
        if data.hasPrefix("\"") {
            return .string(unescape(data.dropFirst(), until: "\"").0)
        }
        if data.hasPrefix("str:\"") {
            return .string(unescape(data.dropFirst(5), until: "\"").0)
        }
        if data.hasPrefix("str(2):\"") {
            return .expandString(unescape(data.dropFirst(8), until: "\"").0)
        }
        if data.hasPrefix("str(7):\"") {
            let joined = unescape(data.dropFirst(8), until: "\"").0
            return .multiString(joined.components(separatedBy: "\0").filter { !$0.isEmpty })
        }
        if data.hasPrefix("dword:") {
            return UInt32(data.dropFirst(6).prefix(8), radix: 16).map(Value.dword)
        }
        if data.hasPrefix("hex:") {
            return .binary(type: 3, hexBytes(data.dropFirst(4)))
        }
        if data.hasPrefix("hex("), let close = data.firstIndex(of: ")"),
           let type = Int(data[data.index(data.startIndex, offsetBy: 4)..<close], radix: 16) {
            var rest = data[data.index(after: close)...]
            if rest.hasPrefix(":") { rest = rest.dropFirst() }
            let bytes = hexBytes(rest)
            switch type {
            case 1: return .string(utf16(bytes).first ?? "")
            case 2: return .expandString(utf16(bytes).first ?? "")
            case 7: return .multiString(utf16(bytes).filter { !$0.isEmpty })
            case 4 where bytes.count >= 4:
                return .dword(bytes.prefix(4).enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) })
            case 0xb where bytes.count >= 8:
                return .qword(bytes.prefix(8).enumerated().reduce(0) { $0 | UInt64($1.element) << (8 * UInt64($1.offset)) })
            default: return .binary(type: type, bytes)
            }
        }
        return nil
    }

    private static func hexBytes(_ s: Substring) -> Data {
        Data(s.split(separator: ",").compactMap { UInt8($0.trimmingCharacters(in: .whitespaces), radix: 16) })
    }

    /// UTF-16LE strings separated by NULs.
    private static func utf16(_ bytes: Data) -> [String] {
        let b = [UInt8](bytes)
        let units = stride(from: 0, to: b.count - 1, by: 2).map { UInt16(b[$0]) | UInt16(b[$0 + 1]) << 8 }
        return units.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF16.self) }
    }

    /// Undoes `dump_strW` escaping up to an unescaped `end` character. Returns the text and whether `end` was found.
    static func unescape(_ s: Substring, until end: Character?) -> (String, Bool) {
        var out = String.UnicodeScalarView()
        let scalars = Array(s.unicodeScalars)
        var i = 0
        func isHex(_ c: Unicode.Scalar) -> Bool { c.properties.isASCIIHexDigit }
        while i < scalars.count {
            let c = scalars[i]
            if let end, Character(c) == end { return (String(out), true) }
            if c == "\\", i + 1 < scalars.count {
                let e = scalars[i + 1]
                i += 2
                switch e {
                case "a": out.append("\u{07}")
                case "b": out.append("\u{08}")
                case "e": out.append("\u{1B}")
                case "f": out.append("\u{0C}")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "v": out.append("\u{0B}")
                case "x":
                    var value: UInt32 = 0, digits = 0
                    while digits < 4, i < scalars.count, isHex(scalars[i]) {
                        value = value * 16 + UInt32(String(scalars[i]), radix: 16)!
                        i += 1; digits += 1
                    }
                    if digits == 0 { out.append("x") } else if let u = Unicode.Scalar(value) { out.append(u) }
                case "0"..."7":
                    var value = e.value - 48, digits = 1
                    while digits < 3, i < scalars.count, ("0"..."7").contains(scalars[i]) {
                        value = value * 8 + (scalars[i].value - 48)
                        i += 1; digits += 1
                    }
                    if let u = Unicode.Scalar(value) { out.append(u) }
                default:
                    out.append(e)   // \\, \", \], \[ and unknown escapes: the character itself
                }
                continue
            }
            out.append(c)
            i += 1
        }
        return (String(out), end == nil)
    }
}
