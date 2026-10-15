#!/usr/bin/env python3
"""Sanity check for project.pbxproj (no Xcode needed): parses the old-style plist and
verifies that every object ID that is referenced also exists.

Usage: python3 scripts/check_pbxproj.py SegmentationValidator.xcodeproj/project.pbxproj
"""
import re
import sys

TOKEN = re.compile(
    r"""
    (?P<ws>\s+)
  | (?P<comment>/\*.*?\*/|//[^\n]*)
  | (?P<punct>[{}()=;,])
  | (?P<quoted>"(?:[^"\\]|\\.)*")
  | (?P<bare>[A-Za-z0-9_$/:.\-+<>]+)
    """,
    re.VERBOSE | re.DOTALL,
)


def tokenize(text):
    pos = 0
    tokens = []
    while pos < len(text):
        match = TOKEN.match(text, pos)
        if not match:
            raise SyntaxError(f"Unexpected character at offset {pos}: {text[pos:pos + 30]!r}")
        kind = match.lastgroup
        if kind not in ("ws", "comment"):
            value = match.group(kind)
            if kind == "quoted":
                value = bytes(value[1:-1], "utf-8").decode("unicode_escape")
            tokens.append((kind, value))
        pos = match.end()
    return tokens


class Parser:
    def __init__(self, tokens):
        self.tokens = tokens
        self.index = 0

    def peek(self):
        return self.tokens[self.index] if self.index < len(self.tokens) else (None, None)

    def take(self, expected=None):
        token = self.peek()
        if expected is not None and token[1] != expected:
            raise SyntaxError(f"Expected {expected!r} but found {token[1]!r} (token {self.index})")
        self.index += 1
        return token

    def value(self):
        kind, value = self.peek()
        if value == "{":
            return self.dictionary()
        if value == "(":
            return self.array()
        if kind in ("quoted", "bare"):
            self.take()
            return value
        raise SyntaxError(f"Unexpected token {value!r} (token {self.index})")

    def dictionary(self):
        self.take("{")
        result = {}
        while self.peek()[1] != "}":
            kind, key = self.take()
            if kind not in ("quoted", "bare"):
                raise SyntaxError(f"Bad dictionary key {key!r}")
            self.take("=")
            if key in result:
                raise SyntaxError(f"Duplicate key {key!r}")
            result[key] = self.value()
            self.take(";")
        self.take("}")
        return result

    def array(self):
        self.take("(")
        result = []
        while self.peek()[1] != ")":
            result.append(self.value())
            if self.peek()[1] == ",":
                self.take(",")
            elif self.peek()[1] != ")":
                raise SyntaxError(f"Expected ',' or ')' in array (token {self.index})")
        self.take(")")
        return result


def main(path):
    text = open(path, encoding="utf-8").read()
    if not text.startswith("// !$*UTF8*$!"):
        raise SystemExit("Missing UTF8 header")
    parser = Parser(tokenize(text))
    root = parser.dictionary()
    if parser.index != len(parser.tokens):
        raise SystemExit("Trailing tokens after root dictionary")

    objects = root["objects"]
    ids = set(objects)
    id_pattern = re.compile(r"^[0-9A-F]{24}$")
    problems = []

    def visit(value, where):
        if isinstance(value, dict):
            for key, child in value.items():
                visit(child, f"{where}.{key}")
        elif isinstance(value, list):
            for child in value:
                visit(child, where)
        elif isinstance(value, str) and id_pattern.match(value) and value not in ids:
            problems.append(f"{where} references missing object {value}")

    for object_id, obj in objects.items():
        if not id_pattern.match(object_id):
            problems.append(f"Bad object id {object_id}")
        if "isa" not in obj:
            problems.append(f"Object {object_id} has no isa")
        visit(obj, f"{object_id}({obj.get('isa')})")
    if root["rootObject"] not in ids:
        problems.append("rootObject missing")

    if problems:
        print("\n".join(problems))
        raise SystemExit(1)
    kinds = sorted({obj["isa"] for obj in objects.values()})
    print(f"OK: {len(objects)} objects ({', '.join(kinds)})")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
