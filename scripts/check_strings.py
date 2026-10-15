#!/usr/bin/env python3
"""Lists user-facing strings in the Swift code that have no German translation in
Localizable.xcstrings (and translations that are no longer used).

Usage: python3 scripts/check_strings.py [--list]
"""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ROOT / "SegmentationValidator"
CATALOG = SOURCES / "Resources" / "Localizable.xcstrings"

LITERAL = r'"((?:[^"\\]|\\.)*)"'
PATTERNS = [
    # String(localized: "…") and L10n.format("…", …)
    re.compile(r'String\(localized:\s*' + LITERAL),
    re.compile(r'L10n\.format\(\s*' + LITERAL),
    # SwiftUI views and modifiers whose first argument is a LocalizedStringKey
    re.compile(
        r'\b(?:Text|Label|Button|Toggle|Picker|DatePicker|LabeledContent|TextField|Section|'
        r'navigationTitle|accessibilityLabel|accessibilityHint|confirmationDialog)\(\s*' + LITERAL
    ),
    # Text(cond ? "a" : "b")
    re.compile(r'\?\s*' + LITERAL + r'\s*:\s*' + LITERAL),
    # LocalizedStringKey parameters of our own views
    re.compile(r'\b(?:title|text):\s*' + LITERAL),
    # App Intents (Shortcuts, Siri)
    re.compile(r'(?:LocalizedStringResource|TypeDisplayRepresentation)\s*=\s*' + LITERAL),
    re.compile(r'\b(?:IntentDescription|dialog:|shortTitle:)\(?\s*' + LITERAL),
]
# Parameters named title/text that take plain strings, not localization keys.
NOT_KEYS_IN = {"NotificationService.swift"}


def unescape(literal):
    return literal.encode("utf-8").decode("unicode_escape").encode("latin-1").decode("utf-8")


COMMENT = re.compile(r"^\s*//.*$", re.MULTILINE)
SYMBOL_NAME = re.compile(r"^[a-z0-9]+(\.[a-z0-9]+)+$")


def keys_in_code():
    found = {}
    for path in sorted(SOURCES.rglob("*.swift")):
        if "/Core/" in str(path):
            continue  # platform independent code has no UI strings
        text = COMMENT.sub("", path.read_text(encoding="utf-8"))
        for pattern in PATTERNS:
            if pattern.pattern.startswith(r'\b(?:title|text)') and path.name in NOT_KEYS_IN:
                continue
            for match in pattern.finditer(text):
                for group in match.groups():
                    if group is None or group == "" or "\\(" in group:
                        continue
                    key = unescape(group)
                    if SYMBOL_NAME.match(key):
                        continue  # SF Symbol names such as "checkmark.circle.fill"
                    found.setdefault(key, path.name)
    return found


def main():
    code = keys_in_code()
    catalog = json.loads(CATALOG.read_text(encoding="utf-8")) if CATALOG.exists() else {"strings": {}}
    strings = catalog.get("strings", {})

    if "--list" in sys.argv:
        for key, file in sorted(code.items(), key=lambda item: (item[1], item[0])):
            print(f"{file}: {key}")
        return

    missing = [key for key in code if "de" not in strings.get(key, {}).get("localizations", {})]
    unused = [key for key in strings if key not in code and not strings[key].get("extractionState") == "manual"]
    for key in sorted(missing):
        print(f"MISSING  {code[key]}: {key!r}")
    for key in sorted(unused):
        print(f"UNUSED   {key!r}")
    print(f"{len(code)} strings in code, {len(missing)} missing, {len(unused)} unused")
    if missing:
        sys.exit(1)


if __name__ == "__main__":
    main()
