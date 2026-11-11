#!/usr/bin/env python3
"""String Catalogs of onwin: extract keys from the code, check translations, exchange them with translators.

    scripts/l10n.py sync              compile with -emit-localized-strings, add new keys to every
                                      Localizable.xcstrings, remove keys no longer in the code
    scripts/l10n.py check             fail if a key lacks a translation, a translation still contains
                                      Russian, format specifiers differ, or OnwinCore / onwinctl look up
                                      a string without their bundle
    scripts/l10n.py export <lang> <file.json> [--all]
                                      keys still untranslated in <lang> (all keys with --all), with
                                      the source files they come from
    scripts/l10n.py leftovers         Russian string literals in the code that the compiler did not extract
                                      as localizable (shown verbatim in every language) — review each one
    scripts/l10n.py import <file.json>
                                      merge translations: {"<target>": {"<key>": {"en": "...",
                                      "kk": {"one": "...", "other": "..."}, ...}}}

The interface language of the source code is Russian (the keys). Languages: ru (source), en, zh-Hans, kk.
Catalogs: app/Sources/{OnwinApp,OnwinCore,onwinctl}/Localizable.xcstrings and OnwinApp/InfoPlist.xcstrings
(Info.plist strings, maintained by hand). Plain Python 3, no dependencies; the catalogs keep the JSON layout
Xcode writes, so they can also be edited in Xcode.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PACKAGE = os.path.join(ROOT, "app")
SOURCE_LANGUAGE = "ru"
# Keep in sync with OnwinLanguage (OnwinCore/Localization.swift), the CompileStringCatalogs plugin and
# CFBundleLocalizations in scripts/build-app.sh.
TRANSLATIONS = ["en", "zh-Hans", "kk"]
TARGETS = ["OnwinApp", "OnwinCore", "onwinctl"]
# Targets whose String(localized:) must name their own bundle (OnwinApp uses Bundle.main).
TARGET_BUNDLES = {"OnwinCore": ".onwinCore", "onwinctl": ".onwinctl"}

CYRILLIC = re.compile(r"[А-Яа-яЁё]")
# Letters Kazakh has and Russian does not.
CYRILLIC_WORD = re.compile(r"[А-Яа-яЁё]{2,}")
KAZAKH_LETTERS = re.compile(r"[ӘәҒғҚқҢңӨөҰұҮүҺһІі]")
# Russian words that do not exist in Kazakh: their presence in a kk string means it was not translated.
RUSSIAN_WORDS = re.compile(
    r"(?<![А-Яа-яЁёӘәҒғҚқҢңӨөҰұҮүҺһІі])(и|в|во|на|для|что|это|или|при|по|из|от|до|без|со|к|ко|как|если|"
    r"нет|есть|уже|ещё|еще|можно|нужно|будет|файлов|пространств[аоеу]?|программ[ауе]?|установк[аиу])"
    r"(?![А-Яа-яЁёӘәҒғҚқҢңӨөҰұҮүҺһІі])"
)
SPECIFIER = re.compile(r"%(?:(\d+)\$)?([-+ #0]*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?[@dDiuUxXoOfFeEgGcCsSpaA%])")


def catalog_path(target, table="Localizable"):
    return os.path.join(PACKAGE, "Sources", target, table + ".xcstrings")


def load(target, table="Localizable"):
    with open(catalog_path(target, table), encoding="utf-8") as f:
        return json.load(f)


def save(target, data, table="Localizable"):
    text = json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : "))
    with open(catalog_path(target, table), "w", encoding="utf-8") as f:
        f.write(text + "\n")


def needs_translation(key):
    return bool(CYRILLIC.search(key))


def source_text(key, entry):
    """The Russian text of a key: its source-language value (keys with defaultValue) or the key itself."""
    unit = entry.get("localizations", {}).get(SOURCE_LANGUAGE, {}).get("stringUnit")
    return unit["value"] if unit and unit.get("value") else key


def specifiers(text):
    """Format specifiers in argument order (positional ones by their position), without %%."""
    result = []
    next_position = 1
    for match in SPECIFIER.finditer(text):
        spec = match.group(2)
        if spec == "%":
            continue
        position = int(match.group(1)) if match.group(1) else next_position
        next_position = position + 1
        # %d, %ld, %lld are interchangeable for a Swift Int in practice; compare the conversion only.
        conversion = spec[-1]
        if conversion in "dDiuU":
            conversion = "d"
        elif conversion in "fFeEgGaA":
            conversion = "f"
        result.append((position, conversion))
    return sorted(result)


def extract():
    """Keys per target, from the .stringsdata files swiftc writes with -emit-localized-strings.
    L10N_REUSE=1 reuses the result of the previous run (build/l10n-keys.json) instead of compiling."""
    cache = os.path.join(ROOT, "build", "l10n-keys.json")
    if os.environ.get("L10N_REUSE") and os.path.exists(cache):
        with open(cache, encoding="utf-8") as f:
            cached = json.load(f)
        for entries in cached.values():
            for info in entries.values():
                info["files"] = set(info["files"])
        return cached
    keys = _extract()
    os.makedirs(os.path.dirname(cache), exist_ok=True)
    with open(cache, "w", encoding="utf-8") as f:
        json.dump({t: {k: {**i, "files": sorted(i["files"])} for k, i in e.items()} for t, e in keys.items()},
                  f, ensure_ascii=False)
    return keys


def _extract():
    out = tempfile.mkdtemp(prefix="onwin-l10n-")
    scratch = os.environ.get("L10N_SCRATCH") or os.path.join(ROOT, "build", "l10n-scratch")
    command = ["swift", "build", "--package-path", PACKAGE, "--scratch-path", scratch]
    if os.environ.get("L10N_PRODUCT"):   # e.g. onwinctl: compiles OnwinCore + onwinctl only
        command += ["--product", os.environ["L10N_PRODUCT"]]
    # swiftc writes .stringsdata only for files it compiles: always build from scratch.
    shutil.rmtree(scratch, ignore_errors=True)
    command += ["-Xswiftc", "-emit-localized-strings", "-Xswiftc", "-emit-localized-strings-path", "-Xswiftc", out]
    print("l10n: " + " ".join(command), file=sys.stderr)
    subprocess.run(command, check=True)
    keys = {}
    for name in os.listdir(out):
        if not name.endswith(".stringsdata"):
            continue
        with open(os.path.join(out, name), encoding="utf-8") as f:
            data = json.load(f)
        source = data.get("source", "")
        match = re.search(r"/Sources/([^/]+)/", source)
        if not match or match.group(1) not in TARGETS + ["onwin-launcher"]:
            continue
        target = match.group(1)
        keys.setdefault(target, {})
        relative = os.path.relpath(source, PACKAGE)
        for table, entries in data.get("tables", {}).items():
            if table != "Localizable":
                print(f"l10n: warning: {relative}: table {table} is not supported", file=sys.stderr)
                continue
            for entry in entries:
                info = keys[target].setdefault(entry["key"], {"comment": "", "files": set()})
                if entry.get("comment"):
                    info["comment"] = entry["comment"]
                if entry.get("value"):   # String(localized: "id", defaultValue: "Текст")
                    info["value"] = entry["value"]
                info["files"].add(f"{relative}:{entry['location']['startingLine']}")
    return keys


def sync():
    keys = extract()
    for target in TARGETS:
        if target not in keys:   # not compiled (L10N_PRODUCT): leave its catalog alone
            continue
        data = load(target)
        strings = data.setdefault("strings", {})
        added = removed = 0
        for key, info in keys[target].items():
            entry = strings.get(key)
            if entry is None:
                entry = strings[key] = {}
                added += 1
            entry.pop("extractionState", None)
            if info["comment"]:
                entry["comment"] = info["comment"]
            if info.get("value"):
                # A key with a defaultValue (two meanings of one Russian word): the Russian text is
                # the source-language value, like Xcode stores it.
                entry.setdefault("localizations", {})[SOURCE_LANGUAGE] = unit(info["value"])
            if not needs_translation(source_text(key, entry)):
                entry["shouldTranslate"] = False
            else:
                entry.pop("shouldTranslate", None)
        for key in [k for k in strings if k not in keys[target]]:
            if strings[key].get("extractionState") == "manual":
                continue
            del strings[key]
            removed += 1
        save(target, data)
        print(f"l10n: {target}: {len(keys[target])} keys, {added} new, {removed} removed")


def plural_forms(localization):
    plural = localization.get("variations", {}).get("plural")
    if plural is None:
        return None
    return {category: form.get("stringUnit", {}).get("value", "") for category, form in plural.items()}


def values_of(localization):
    """All texts of a localization: one string unit or the plural forms."""
    forms = plural_forms(localization)
    if forms is not None:
        return list(forms.values())
    unit = localization.get("stringUnit")
    return [unit.get("value", "")] if unit else []


def check():
    problems = []
    for target in TARGETS + ["OnwinApp:InfoPlist"]:
        name, _, table = target.partition(":")
        data = load(name, table or "Localizable")
        is_plist = bool(table)
        for key, entry in data.get("strings", {}).items():
            source_key = key if is_plist else source_text(key, entry)
            if entry.get("shouldTranslate") is False or not (needs_translation(source_key) or is_plist):
                continue
            localizations = entry.get("localizations", {})
            key_specs = specifiers(source_key)
            source = localizations.get(SOURCE_LANGUAGE)
            if source is not None and plural_forms(source) is not None:
                for category, value in plural_forms(source).items():
                    if not is_plist and specifiers(value) != key_specs:
                        problems.append(f"{target}: ru/{category}: format specifiers differ: {key!r} → {value!r}")
            for language in TRANSLATIONS:
                localization = localizations.get(language)
                texts = values_of(localization) if localization else []
                if not texts or not all(texts):
                    problems.append(f"{target}: {language}: missing translation: {key!r}")
                    continue
                if plural_forms(localization) is not None and "other" not in plural_forms(localization):
                    problems.append(f"{target}: {language}: plural without 'other': {key!r}")
                for text in texts:
                    if not is_plist and specifiers(text) != key_specs:
                        problems.append(f"{target}: {language}: format specifiers differ: {key!r} → {text!r}")
                    if language in ("en", "zh-Hans") and CYRILLIC.search(text):
                        problems.append(f"{target}: {language}: Cyrillic in translation: {key!r} → {text!r}")
                    if language == "kk" and needs_translation(source_key):
                        # The same text is fine for loanwords («Графика», «Каталог», «Журнал: %@»).
                        if text == source_key and len(CYRILLIC_WORD.findall(source_key)) > 2:
                            problems.append(f"{target}: kk: same as Russian: {key!r}")
                        elif RUSSIAN_WORDS.search(text) or (len(CYRILLIC.findall(text)) > 45 and not KAZAKH_LETTERS.search(text)):
                            problems.append(f"{target}: kk: looks Russian: {key!r} → {text!r}")
    # Lookups that would miss their bundle: OnwinCore / onwinctl must pass bundle:.
    for target, bundle in TARGET_BUNDLES.items():
        folder = os.path.join(PACKAGE, "Sources", target)
        for name in sorted(os.listdir(folder)):
            if not name.endswith(".swift"):
                continue
            with open(os.path.join(folder, name), encoding="utf-8") as f:
                text = f.read()
            for match in re.finditer(r"String\(localized:", text):
                line_start = text.rfind("\n", 0, match.start()) + 1
                if text[line_start:match.start()].lstrip().startswith("//"):
                    continue
                # The call may span lines: find its closing parenthesis.
                window = text[match.start():match.start() + 2000]
                depth, end = 0, len(window)
                for i, c in enumerate(window):
                    if c == "(":
                        depth += 1
                    elif c == ")":
                        depth -= 1
                        if depth == 0:
                            end = i
                            break
                if f"bundle: {bundle}" not in window[:end + 1]:
                    line = text.count("\n", 0, match.start()) + 1
                    problems.append(f"{target}/{name}:{line}: String(localized:) without bundle: {bundle}")
    for problem in problems:
        print(problem)
    print(f"l10n: {len(problems)} problem(s)", file=sys.stderr)
    return 1 if problems else 0


def export(language, path, everything=False):
    keys = extract()
    result = {}
    for target in TARGETS:
        strings = load(target).get("strings", {})
        for key, info in sorted(keys.get(target, {}).items()):
            entry = strings.get(key, {})
            if entry.get("shouldTranslate") is False or not needs_translation(source_text(key, entry)):
                continue
            if not everything and language in entry.get("localizations", {}):
                continue
            result.setdefault(target, {})[key] = {
                "source": source_text(key, entry),
                "comment": info["comment"] or entry.get("comment", ""),
                "files": sorted(info["files"]),
            }
    with open(path, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=1)
    print(f"l10n: {sum(len(v) for v in result.values())} keys → {path}")


def unit(value):
    return {"stringUnit": {"state": "translated", "value": value}}


def import_(path):
    with open(path, encoding="utf-8") as f:
        incoming = json.load(f)
    for target, entries in incoming.items():
        name, _, table = target.partition(":")
        data = load(name, table or "Localizable")
        strings = data.setdefault("strings", {})
        count = 0
        for key, languages in entries.items():
            if key not in strings:
                print(f"l10n: warning: {target}: unknown key skipped: {key!r}", file=sys.stderr)
                continue
            localizations = strings[key].setdefault("localizations", {})
            for language, value in languages.items():
                if isinstance(value, dict):
                    localizations[language] = {"variations": {"plural": {c: unit(v) for c, v in value.items()}}}
                elif value:
                    localizations[language] = unit(value)
                count += 1
        save(name, data, table or "Localizable")
        print(f"l10n: {target}: {count} translations merged")


def swift_literals(text):
    """(line, parts) for every string literal outside comments; parts alternate text and None for an
    interpolation. Handles single-line and triple-quoted literals, escapes and nested interpolations
    with strings inside."""
    result = []
    i, n = 0, len(text)

    def read_string(i, multiline):
        """i points after the opening quote(s). Returns (end index after closing quotes, parts)."""
        parts, current = [], []
        while i < n:
            if multiline and text.startswith('"""', i):
                parts.append("".join(current))
                return i + 3, parts
            c = text[i]
            if not multiline and c == '"':
                parts.append("".join(current))
                return i + 1, parts
            if c == "\\" and i + 1 < n:
                if text[i + 1] == "(":
                    parts.append("".join(current))
                    current = []
                    parts.append(None)
                    depth, i = 1, i + 2
                    while i < n and depth:
                        if text.startswith('"""', i):
                            i, _ = read_string(i + 3, True)
                            continue
                        if text[i] == '"':
                            i, _ = read_string(i + 1, False)
                            continue
                        depth += {"(": 1, ")": -1}.get(text[i], 0)
                        i += 1
                    continue
                current.append(text[i:i + 2])
                i += 2
                continue
            current.append(c)
            i += 1
        parts.append("".join(current))
        return i, parts

    while i < n:
        if text.startswith("//", i):
            i = text.find("\n", i)
            i = n if i < 0 else i
        elif text.startswith("/*", i):
            i = text.find("*/", i)
            i = n if i < 0 else i + 2
        elif text.startswith('"""', i):
            line = text.count("\n", 0, i) + 1
            i, parts = read_string(i + 3, True)
            result.append((line, parts, True))
        elif text[i] == '"':
            line = text.count("\n", 0, i) + 1
            i, parts = read_string(i + 1, False)
            result.append((line, parts, False))
        else:
            i += 1
    return result


def dedent_multiline(parts):
    """A triple-quoted literal as the compiler sees it: without the newline after the opening quotes,
    the line before the closing ones, and the closing delimiter's indentation on every line."""
    if not parts or parts[-1] is None:
        return parts
    last = parts[-1]
    indent = last[last.rfind("\n") + 1:] if "\n" in last else ""
    if indent.strip():
        return parts
    parts = list(parts)
    parts[-1] = last[:last.rfind("\n")] if "\n" in last else last
    if parts[0] is not None and parts[0].startswith("\n"):
        parts[0] = parts[0][1:]
    return [p if p is None else re.sub("(^|\n)" + re.escape(indent), r"\1", p) if i == 0
            else p.replace("\n" + indent, "\n") for i, p in enumerate(parts)]


def leftovers():
    keys = extract()
    found = 0
    for target in TARGETS + ["onwin-launcher"]:
        folder = os.path.join(PACKAGE, "Sources", target)
        extracted = set(keys.get(target, {})) | {i["value"] for i in keys.get(target, {}).values() if i.get("value")}
        for name in sorted(os.listdir(folder)):
            if not name.endswith(".swift"):
                continue
            with open(os.path.join(folder, name), encoding="utf-8") as f:
                text = f.read()
            for line, parts, multiline in swift_literals(text):
                if multiline:
                    parts = dedent_multiline(parts)
                joined = "".join(p for p in parts if p is not None)
                if not CYRILLIC.search(joined):
                    continue
                # Escapes as the compiler writes them into the key (\n stays \n in .stringsdata as a newline).
                regex = "".join(
                    r"%(\d+\$)?[-+ #0]*\d*(\.\d+)?(hh|h|ll|l|q|z|t|j)?[@dDiuUxXoOfFeEgGcCsSpaA]" if p is None
                    else re.escape(p.replace("\\n", "\n").replace("\\t", "\t").replace('\\"', '"').replace("\\\\", "\\").replace("%", "%%"))
                    for p in parts)
                pattern = re.compile("^" + regex + "$", re.S)
                if any(pattern.match(key) for key in extracted):
                    continue
                found += 1
                literal = "".join("\\(…)" if p is None else p for p in parts)
                print(f"{target}/{name}:{line}: {literal[:140]}")
    print(f"l10n: {found} Russian literal(s) not extracted", file=sys.stderr)


def main(argv):
    if len(argv) >= 2 and argv[1] == "sync":
        sync()
    elif len(argv) >= 2 and argv[1] == "leftovers":
        leftovers()
    elif len(argv) >= 2 and argv[1] == "check":
        return check()
    elif len(argv) >= 4 and argv[1] == "export":
        export(argv[2], argv[3], "--all" in argv)
    elif len(argv) == 3 and argv[1] == "import":
        import_(argv[2])
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
