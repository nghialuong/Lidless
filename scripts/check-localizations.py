#!/usr/bin/env python3
"""Check translation coverage and printf arguments without requiring Xcode."""
import json
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]


def read_strings(path):
    result = {}
    for line in path.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith("//"):
            continue
        match = re.fullmatch(r'("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*");', line)
        if not match:
            raise ValueError(f"Invalid strings entry: {path}: {line}")
        key, value = map(json.loads, match.groups())
        if key in result:
            raise ValueError(f"Duplicate key: {path}: {key}")
        result[key] = value
    return result


english = read_strings(root / "Resources/Localizations/en.lproj/Localizable.strings")
chinese = read_strings(root / "Resources/Localizations/zh-Hans.lproj/Localizable.strings")
assert english.keys() == chinese.keys(), "English and Chinese key sets differ"
placeholder = re.compile(r"%(?:\d+\$)?(?:[-+0 #]*\d*(?:\.\d+)?(?:hh|ll|[hljztL])?)?[@diuoxXfFeEgGaAcCsSp%]")
for key, value in chinese.items():
    assert english[key] == key, f"English fallback changed: {key}"
    assert placeholder.findall(key) == placeholder.findall(value), f"Format arguments differ: {key}"
    assert key.count("**") == value.count("**"), f"Markdown emphasis differs: {key}"
    assert key.count(chr(96)) == value.count(chr(96)), f"Markdown code differs: {key}"

literal_call = re.compile(r'L10n\.(?:tr|format)\(\s*"((?:[^"\\]|\\.)*)"')
for source in (root / "Sources").rglob("*.swift"):
    for match in literal_call.finditer(source.read_text()):
        literal = re.sub(r'\\u\{([0-9a-fA-F]+)\}', lambda m: chr(int(m[1], 16)), match[1])
        key = json.loads('"' + literal + '"')
        assert key in english, f"Missing translation in {source.relative_to(root)}: {key}"

print(f"OK: {len(english)} matching English / Simplified Chinese entries; source coverage and format arguments checked.")
