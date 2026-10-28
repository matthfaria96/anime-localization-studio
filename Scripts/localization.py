#!/usr/bin/env python3
"""Keeps the English table in step with the texts in the code.

The texts are written in Brazilian Portuguese in the source; the compiler lists every one it
localizes (.stringsdata files under .build, made by any `swift build`). This script:

  check             lists the texts that have no English translation (exit 1 when there are any)
  write [new.json]  rewrites pt-BR.lproj (each text as itself) and en.lproj (the translations
                    kept for texts still in the code, plus those in new.json: {"pt": "en"})

Run it after a build. Format specifiers (%@, %lld, %%) must match between a text and its translation.
"""
import glob
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
RESOURCES = os.path.join(ROOT, "Sources/AnimeLocalizationStudio/Resources")
TABLES = {lang: os.path.join(RESOURCES, f"{lang}.lproj/Localizable.strings") for lang in ("en", "pt-BR")}
SPEC = re.compile(r"%(\d+\$)?(lld|ld|d|@|lf|f|%)")


def code_texts():
    """The localized texts of the code, in source order, from the newest .stringsdata of each file."""
    newest = {}
    pattern = os.path.join(ROOT, ".build/out/Intermediates.noindex/*/*/*.build/Objects-normal/*/*.stringsdata")
    for path in glob.glob(pattern):
        data = json.load(open(path))
        source = os.path.realpath(data.get("source", ""))
        if not source.startswith(os.path.join(ROOT, "Sources") + os.sep):
            continue
        if source not in newest or os.path.getmtime(path) > os.path.getmtime(newest[source][0]):
            newest[source] = (path, data)
    if not newest:
        sys.exit("No .stringsdata found: build the app first (swift build).")
    texts = {}
    for source in sorted(newest):
        for entries in newest[source][1].get("tables", {}).values():
            place = lambda e: (e.get("location", {}).get("startingLine", 0), e.get("location", {}).get("startingColumn", 0))
            for entry in sorted(entries, key=place):
                texts.setdefault(entry["key"], os.path.relpath(source, ROOT))
    return texts


def read_table(path):
    if not os.path.exists(path):
        return {}
    out = subprocess.run(["plutil", "-convert", "json", "-o", "-", path], capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


def quote(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t") + '"'


def write_table(path, header, pairs):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lines = [f"/* {header} */", ""]
    current = None
    for key, value, source in pairs:
        if source != current:
            lines += ["", f"/* {source} */"] if current else [f"/* {source} */"]
            current = source
        lines.append(f"{quote(key)} = {quote(value)};")
    open(path, "w", encoding="utf-8").write("\n".join(lines) + "\n")


def specifiers(text):
    return sorted(m.group(0) for m in SPEC.finditer(text))


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "check"
    texts = code_texts()
    english = read_table(TABLES["en"])
    if command == "write":
        if len(sys.argv) > 2:
            english.update(json.load(open(sys.argv[2])))
        kept = [(k, english[k], s) for k, s in texts.items() if k in english]
        write_table(TABLES["en"], "English. Keys are the Brazilian Portuguese texts of the code (Scripts/localization.py).", kept)
        write_table(TABLES["pt-BR"], "Brazilian Portuguese: each text as itself, so macOS never falls back to English.",
                    [(k, k, s) for k, s in texts.items()])
    missing = [(k, s) for k, s in texts.items() if k not in english]
    wrong = [k for k in texts if k in english and specifiers(k) != specifiers(english[k])]
    for key, source in missing:
        print(f"missing  {source}: {json.dumps(key, ensure_ascii=False)}")
    for key in wrong:
        print(f"format   {json.dumps(key, ensure_ascii=False)} → {json.dumps(english[key], ensure_ascii=False)}")
    print(f"{len(texts)} texts, {len(missing)} without English, {len(wrong)} with mismatched specifiers", file=sys.stderr)
    sys.exit(1 if missing or wrong else 0)


if __name__ == "__main__":
    main()
