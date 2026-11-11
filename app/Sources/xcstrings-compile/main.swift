import Foundation

// xcstrings-compile <output dir> <lang,lang,...> <catalog.xcstrings>...
//
// Build tool of the CompileStringCatalogs plugin: turns String Catalogs into the classic
// <lang>.lproj/<table>.strings (plain strings) and <table>.stringsdict (plural variations) that
// Foundation reads at run time. Supports what onwin uses: string units and plural variations of the
// whole string (one integer argument is the plural selector). A language without a translation
// gets no entry, so the lookup falls back to the key (the Russian source text).

struct Failure: Error, CustomStringConvertible { let description: String }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("xcstrings-compile: error: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count >= 4 else { fail("usage: xcstrings-compile <output dir> <languages> <catalog>...") }
let outputDir = URL(fileURLWithPath: arguments[1])
let languages = arguments[2].split(separator: ",").map(String.init)
let catalogs = arguments.dropFirst(3).map { URL(fileURLWithPath: $0) }

/// Format specifiers of a printf-style string, in argument order (supports %@, %lld, %d, %lf, %f,
/// %ld, %lu, %llu, %u, %%, and positional %1$@).
func specifiers(in format: String) -> [(range: Range<String.Index>, position: Int?, spec: String)] {
    var result: [(Range<String.Index>, Int?, String)] = []
    var index = format.startIndex
    while let percent = format[index...].firstIndex(of: "%") {
        var cursor = format.index(after: percent)
        guard cursor < format.endIndex else { break }
        if format[cursor] == "%" { index = format.index(after: cursor); continue }
        var digits = ""
        var probe = cursor
        while probe < format.endIndex, format[probe].isNumber { digits.append(format[probe]); probe = format.index(after: probe) }
        var position: Int?
        if !digits.isEmpty, probe < format.endIndex, format[probe] == "$" {
            position = Int(digits)
            cursor = format.index(after: probe)
        }
        var spec = ""
        while cursor < format.endIndex {
            let c = format[cursor]
            spec.append(c)
            cursor = format.index(after: cursor)
            if "@dDiuUxXoOfFeEgGcCsSpaA".contains(c) { break }
        }
        result.append((percent..<cursor, position, spec))
        index = cursor
    }
    return result
}

/// Rewrites every specifier as positional (%1$@, %2$lld…) so a plural form may use the arguments
/// in any order.
func positional(_ format: String) -> String {
    var output = ""
    var last = format.startIndex
    var next = 1
    for item in specifiers(in: format) {
        output += format[last..<item.range.lowerBound]
        let position = item.position ?? next
        next = position + 1
        output += "%\(position)$\(item.spec)"
        last = item.range.upperBound
    }
    output += format[last...]
    return output
}

func isInteger(_ spec: String) -> Bool { spec.hasSuffix("d") || spec.hasSuffix("i") || spec.hasSuffix("u") }

for catalogURL in catalogs {
    let table = catalogURL.deletingPathExtension().lastPathComponent
    guard let data = try? Data(contentsOf: catalogURL),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let strings = root["strings"] as? [String: Any] else {
        fail("\(catalogURL.path): not a String Catalog")
    }
    let sourceLanguage = root["sourceLanguage"] as? String ?? "en"

    for language in languages {
        var plain: [String: String] = [:]
        var plurals: [String: Any] = [:]
        for (key, value) in strings {
            guard let entry = value as? [String: Any] else { continue }
            let localizations = entry["localizations"] as? [String: Any] ?? [:]
            guard let localization = localizations[language] as? [String: Any] else {
                // The source language may omit an entry whose text equals the key: the lookup falls
                // back to the key anyway.
                continue
            }
            if let unit = localization["stringUnit"] as? [String: Any] {
                if let text = unit["value"] as? String, !text.isEmpty { plain[key] = text }
            } else if let variations = localization["variations"] as? [String: Any] {
                guard let plural = variations["plural"] as? [String: Any] else {
                    fail("\(table): \"\(key)\" [\(language)]: only plural variations are supported")
                }
                let keySpecs = specifiers(in: key)
                guard let selector = keySpecs.enumerated().first(where: { isInteger($0.element.spec) }) else {
                    fail("\(table): \"\(key)\" [\(language)]: plural variation without an integer argument")
                }
                let position = selector.element.position ?? (selector.offset + 1)
                var rule: [String: Any] = [
                    "NSStringFormatSpecTypeKey": "NSStringPluralRuleType",
                    "NSStringFormatValueTypeKey": String(selector.element.spec),
                ]
                for (category, form) in plural {
                    guard let unit = (form as? [String: Any])?["stringUnit"] as? [String: Any],
                          let text = unit["value"] as? String else { continue }
                    rule[category] = positional(text)
                }
                guard rule["other"] != nil else { fail("\(table): \"\(key)\" [\(language)]: plural without \"other\"") }
                plurals[key] = [
                    "NSStringLocalizedFormatKey": "%\(position)$#@count@",
                    "count": rule,
                ]
            }
        }
        _ = sourceLanguage
        let lproj = outputDir.appending(path: "\(language).lproj")
        do {
            try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
            // .strings files may be property lists; this avoids escaping rules of the text format.
            try PropertyListSerialization.data(fromPropertyList: plain, format: .binary, options: 0)
                .write(to: lproj.appending(path: "\(table).strings"), options: .atomic)
            try PropertyListSerialization.data(fromPropertyList: plurals, format: .binary, options: 0)
                .write(to: lproj.appending(path: "\(table).stringsdict"), options: .atomic)
        } catch {
            fail("\(lproj.path): \(error)")
        }
    }
}
