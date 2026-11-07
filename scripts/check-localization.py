#!/usr/bin/env python3
"""Reports localization keys used in the Swift sources that are missing from a translation.

    ./scripts/check-localization.py              # checks Localization/de.lproj
    ./scripts/check-localization.py --lang fr    # another language
    ./scripts/check-localization.py --keys       # just lists every key found
    ./scripts/check-localization.py --suspicious # also lists literals that look like UI text but aren't localized

Keys are collected from `String(localized: "…")` in every target except the CLI, and from SwiftUI
initializers and modifiers that take a `LocalizedStringKey` (`Text("…")`, `Button("…")`, `.help("…")`, …)
in the app. Interpolations become format specifiers the way SwiftUI and Foundation build keys
(`String` → %@, `Int` → %lld, …). Types are inferred from the expression with heuristics; expressions it
can't classify are reported, and keys are matched ignoring the specifier type so a wrong guess can't hide a
missing translation. Exits with status 1 if anything is missing.
"""
import argparse
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE_DIRS = ["Sources/ReclaimApp", "Sources/ReclaimCore"]
APP_DIR = "Sources/ReclaimApp"

# SwiftUI APIs whose first (unlabeled) argument is a LocalizedStringKey when given a literal.
UI_CALLS = {
    "Text", "Button", "Label", "Toggle", "Picker", "Menu", "Section", "TableColumn", "navigationTitle", "help",
    "ContentUnavailableView", "confirmationDialog", "alert", "LabeledContent", "CommandMenu", "Link", "Window",
    "accessibilityLabel", "accessibilityHint", "accessibilityAction", "TextField", "SearchField", "coreRow",
    "value",
}
# Labeled arguments that are keys too.
KEY_LABELS = {"accessibilityAction": {"named"}, "SearchField": {"prompt"}}

# How interpolated expressions turn into format specifiers. First match wins.
STRING_HINTS = [
    r"ByteSize\.format", r"approximateDuration", r"signedSize", r"\.formatted\(", r"\bString\(", r"localizedDescription", r"[Pp]ath\b", r"\.name\b",
    r"\.title\b", r"\.label\b", r"shortDate", r"rebuildHint", r"\bmessage\b", r"periodDescription", r"percentText",
    r"countText\(", r"fileCount\(", r"slotTime", r"displayName", r"projectName", r"lastPathComponent",
    r"abbreviatedPath", r"\bdate\b", r"\btime\b", r"\bevery\b", r"\bstart\b", r"\bsize\b", r"\bamount\b",
    r"\bitems\b", r"\bnames\b", r"\btext\b", r"\blist\b", r"\bcores\b", r"\bproject\b", r"\bproblem\b",
    r"\bcommand\b", r"\bid\b", r"\bwhat\b", r"lowercasedFirst", r"totalCount", r"\.joined\(", r"\bapp\b",
    r"appName", r"\$0$", r"ollama", r"\bwasted\b", r"^title$", r"^name$",
]
INT_HINTS = [
    r"\.count\b", r"[cC]ount\b", r"[dD]ays\b", r"\bday\b", r"\bgb\b", r"seconds", r"\bs / ", r"\bInt\(",
    r"max\(0, unused\)", r"processCount", r"coreCount", r"\bperformance(Cores)?\b", r"\befficiency(Cores)?\b",
    r"\bbroken\b", r"\bremaining\b", r"\bminute\b",
]
INT32_HINTS = [r"^status$"]
# `$0` is an Int in a few closures; listed by source line fragment.
INT_CONTEXTS = [r'Text\("\\\(\$0\) GB available"\)']


def infer_specifier(expr, line):
    expr = expr.strip()
    if expr == "$0" and any(re.search(p, line) for p in INT_CONTEXTS):
        return "%lld"
    for pattern in INT32_HINTS:
        if re.search(pattern, expr):
            return "%d"
    if re.search(r"\.count(\s*[-+*]\s*\d+)?$", expr):
        return "%lld"
    for pattern in STRING_HINTS:
        if re.search(pattern, expr):
            return "%@"
    for pattern in INT_HINTS:
        if re.search(pattern, expr):
            return "%lld"
    return None


class Literal:
    def __init__(self, path, line, start, parts, raw, nested):
        self.path, self.line, self.start, self.parts, self.raw, self.nested = path, line, start, parts, raw, nested

    @property
    def has_interpolation(self):
        return any(kind == "expr" for kind, _ in self.parts)

    def key(self, source_line):
        """The localization key, plus expressions whose type couldn't be inferred."""
        unknown = []
        out = []
        for kind, value in self.parts:
            if kind == "text":
                out.append(value.replace("%", "%%") if self.has_interpolation else value)
            else:
                spec = infer_specifier(value, source_line)
                if spec is None:
                    unknown.append(value)
                    spec = "%@"
                out.append(spec)
        return "".join(out), unknown


ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", '"': '"', "'": "'", "\\": "\\"}


class Scanner:
    """A small Swift lexer: finds string literals (with interpolations) and masks literals and comments."""

    def __init__(self, path, text):
        self.path, self.text = path, text
        self.literals = []
        self.mask = list(text)

    def line_of(self, index):
        return self.text.count("\n", 0, index) + 1

    def blank(self, start, end, keep_quotes=False):
        for index in range(start, end):
            if self.mask[index] != "\n":
                self.mask[index] = " "
        if keep_quotes:
            self.mask[start] = '"'
            self.mask[end - 1] = '"'

    def scan(self):
        text, i, n = self.text, 0, len(self.text)
        while i < n:
            if text.startswith("//", i):
                end = text.find("\n", i)
                end = n if end < 0 else end
                self.blank(i, end)
                i = end
            elif text.startswith("/*", i):
                depth, j = 1, i + 2
                while j < n and depth:
                    if text.startswith("/*", j):
                        depth, j = depth + 1, j + 2
                    elif text.startswith("*/", j):
                        depth, j = depth - 1, j + 2
                    else:
                        j += 1
                self.blank(i, j)
                i = j
            elif text[i] == "#" and re.match(r'#+"', text[i:]):
                hashes = re.match(r"#+", text[i:]).group(0)
                quote = '"""' if text.startswith(hashes + '"""', i) else '"'
                close = quote + hashes
                end = text.find(close, i + len(hashes) + len(quote))
                end = n if end < 0 else end + len(close)
                self.blank(i, end)
                i = end
            elif text.startswith('"""', i):
                end = text.find('"""', i + 3)
                end = n if end < 0 else end + 3
                self.blank(i, end)
                i = end
            elif text[i] == '"':
                literal, end = self.string(i, nested=False)
                self.literals.append(literal)
                self.blank(i, end, keep_quotes=True)
                i = end
            else:
                i += 1
        self.mask = "".join(self.mask)
        return self

    def string(self, start, nested):
        """Parses a "…" literal starting at `start`; returns the literal and the index after it."""
        text, i = self.text, start + 1
        parts, buffer = [], []
        while i < len(text) and text[i] != '"':
            char = text[i]
            if char == "\\":
                following = text[i + 1]
                if following == "(":
                    if buffer:
                        parts.append(("text", "".join(buffer)))
                        buffer = []
                    expr, i = self.interpolation(i + 2)
                    parts.append(("expr", expr))
                    continue
                if following == "u":
                    close = text.index("}", i)
                    buffer.append(chr(int(text[i + 3:close], 16)))
                    i = close + 1
                    continue
                buffer.append(ESCAPES.get(following, following))
                i += 2
                continue
            buffer.append(char)
            i += 1
        if buffer:
            parts.append(("text", "".join(buffer)))
        literal = Literal(self.path, self.line_of(start), start, parts, text[start:i + 1], nested)
        return literal, i + 1

    def interpolation(self, i):
        """Parses an interpolated expression up to its closing parenthesis, collecting nested literals."""
        text, depth, start = self.text, 1, i
        while depth:
            char = text[i]
            if char == '"':
                literal, i = self.string(i, nested=True)
                self.literals.append(literal)
                continue
            if char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
            i += 1
        return text[start:i - 1], i


def enclosing_call(mask, index):
    """The innermost unclosed call before `index`: (call name or None, bracket position).

    Grouping parentheses, as in `Text(a ? (b ? "x" : "y") : "z")`, are skipped.
    """
    depth = 0
    for position in range(index - 1, -1, -1):
        char = mask[position]
        if char in ")]}":
            depth += 1
        elif char in "([{":
            if depth == 0:
                if char != "(":
                    return None, position
                name = re.search(r"([A-Za-z_][A-Za-z0-9_]*)\s*$", mask[:position])
                if name:
                    return name.group(1), position
                if not re.search(r"[?:]\s*$", mask[:position]):
                    return None, position
                continue  # grouping parentheses inside a ternary
            depth -= 1
    return None, -1


def split_top_level(text):
    depth, last, pieces = 0, 0, []
    for index, char in enumerate(text):
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif char == "," and depth == 0:
            pieces.append(text[last:index])
            last = index + 1
    pieces.append(text[last:])
    return pieces


def classify(scanner, literal):
    """Returns 'localized', 'ui', or None."""
    before = scanner.text[:literal.start].rstrip()
    if before.endswith("String(localized:"):
        return "localized"
    if literal.nested or not literal.path.startswith(APP_DIR):
        return None
    name, bracket = enclosing_call(scanner.mask, literal.start)
    if name not in UI_CALLS:
        return None
    inner = list(scanner.mask[bracket + 1:literal.start])
    # Blank grouping parentheses that are still open at the literal, so `cond ? (other ? ` reads as a ternary.
    open_parens = []
    for position, char in enumerate(inner):
        if char == "(":
            open_parens.append(position)
        elif char == ")" and open_parens:
            open_parens.pop()
    for position in open_parens:
        inner[position] = " "
    arguments = split_top_level("".join(inner))
    argument = arguments[-1]
    label = re.match(r"\s*([A-Za-z_]\w*)\s*:(?!:)\s*", argument)
    if label and not re.match(r"\s*\w+\s*:\s*$", argument) and "?" in argument[:label.end()]:
        label = None  # `cond ? x : "…"`, not a label
    if label:
        if label.group(1) not in KEY_LABELS.get(name, set()):
            return None
        argument = argument[label.end():]
    elif len(arguments) > 1:
        return None
    prefix = argument.strip()
    if prefix.endswith("??"):
        return None
    if prefix and not (prefix.endswith("?") or prefix.endswith(":")):
        return None
    return "ui"


def looks_like_ui_text(literal):
    text = "".join(value for kind, value in literal.parts if kind == "text").strip()
    if len(re.findall(r"[A-Za-z]", text)) < 2:
        return False
    if re.fullmatch(r"[\w.\-/~:$*{}@+]+", text) and not re.match(r"[A-Z][a-z]+$", text):
        return False  # identifiers, paths, keys, symbol names
    return " " in text or re.match(r"[A-Z][a-z]", text) is not None


NON_UI_CONTEXT = re.compile(
    r"(systemImage|systemName|forKey|identifier|id|named|prefix|suffix|forType|path|filePath|pattern|"
    r"bundleIdentifier|command|prompt: nil)\s*:\s*$|(appending|hasPrefix|hasSuffix|contains|run|find|"
    r"runAsAdministrator|replacingOccurrences|Notification\.Name|URL|string|split|components)\(\s*$"
)


def collect():
    keys = {}  # key -> list of (path, line)
    unknown = []
    suspicious = []
    for directory in SOURCE_DIRS:
        for path in sorted((ROOT / directory).rglob("*.swift")):
            relative = str(path.relative_to(ROOT))
            scanner = Scanner(relative, path.read_text(encoding="utf-8")).scan()
            lines = scanner.text.split("\n")
            for literal in scanner.literals:
                kind = classify(scanner, literal)
                source_line = lines[literal.line - 1]
                if kind:
                    key, unresolved = literal.key(source_line)
                    if not re.search(r"[A-Za-z]", SPECIFIER.sub("", key)):
                        continue  # "", "—", "%lld": nothing to translate
                    keys.setdefault(key, []).append((relative, literal.line))
                    unknown += [(relative, literal.line, expr) for expr in unresolved]
                elif looks_like_ui_text(literal):
                    before = scanner.text[max(0, literal.start - 80):literal.start]
                    if not NON_UI_CONTEXT.search(before) and "///" not in source_line.split('"')[0]:
                        suspicious.append((relative, literal.line, literal.raw))
    return keys, unknown, suspicious


def load_table(path):
    if not path.exists():
        return {}
    result = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(path)], capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"{path}: {result.stderr.strip()}")
    return json.loads(result.stdout)


SPECIFIER = re.compile(r"%(?:\d+\$)?(?:ll|l|h)?[@dDuUxXoOfeEgGcCsSpaA]")


def shape(key):
    """The key with every format specifier replaced, for type-insensitive matching."""
    return SPECIFIER.sub("%*", key)


ARGUMENT = re.compile(r"%(?:(\d+)\$)?(#@\w+@|(?:ll|l|h)?[@dDuUxXoOfeEgGcCsSpaA])")


def arguments(text, variables=None):
    """Maps argument positions to their types, e.g. {1: '@', 2: 'lld'}. `%%` is skipped."""
    result, position = {}, 0
    for match in ARGUMENT.finditer(text.replace("%%", "")):
        index = int(match.group(1)) if match.group(1) else position + 1
        position = index
        kind = match.group(2)
        if kind.startswith("#@"):
            kind = (variables or {}).get(kind[2:-1], {}).get("NSStringFormatValueTypeKey", "?")
        result.setdefault(index, set()).add(kind)
    return result


def check_arguments(strings, plurals):
    """Translations whose arguments don't match the key's (count or types)."""
    problems = []
    for key, value in strings.items():
        expected = arguments(key) if SPECIFIER.search(key.replace("%%", "")) else {}
        actual = arguments(value) if expected else {}
        if expected != actual:
            problems.append((key, value))
    for key, entry in plurals.items():
        expected = arguments(key)
        format_key = entry.get("NSStringLocalizedFormatKey", "")
        if arguments(format_key, entry) != expected:
            problems.append((key, format_key))
        for name, rules in entry.items():
            if not isinstance(rules, dict):
                continue
            for rule, text in rules.items():
                if rule.startswith("NS"):
                    continue
                for index, kinds in arguments(text).items():
                    if kinds - expected.get(index, set()):
                        problems.append((key, text))
    return problems


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--lang", default="de")
    parser.add_argument("--keys", action="store_true", help="list every key found and exit")
    parser.add_argument("--suspicious", action="store_true", help="also list literals that look unlocalized")
    args = parser.parse_args()

    keys, unknown, suspicious = collect()
    if args.keys:
        for key in sorted(keys):
            print(json.dumps(key, ensure_ascii=False))
        return 0

    folder = ROOT / "Localization" / f"{args.lang}.lproj"
    strings = load_table(folder / "Localizable.strings")
    plurals = load_table(folder / "Localizable.stringsdict")
    translated = set(strings) | set(plurals)
    translated_shapes = {shape(key): key for key in translated}

    missing, mismatched = [], []
    for key in sorted(keys):
        if key in translated:
            continue
        if shape(key) in translated_shapes:
            mismatched.append((key, translated_shapes[shape(key)]))
        else:
            missing.append(key)
    used_shapes = {shape(key) for key in keys}
    unused = sorted(key for key in translated if shape(key) not in used_shapes)
    untranslated = sorted(key for key, value in strings.items() if value == key and re.search(r"[A-Za-z]{3}", key))

    print(f"{len(keys)} keys in the sources, {len(translated)} in {folder.relative_to(ROOT)}")
    print(f"translated: {len(keys) - len(missing) - len(mismatched)}  missing: {len(missing)}  "
          f"specifier mismatches: {len(mismatched)}  unused: {len(unused)}")
    for key in missing:
        where = ", ".join(f"{path}:{line}" for path, line in keys[key][:2])
        print(f"MISSING     {json.dumps(key, ensure_ascii=False)}  ({where})")
    for key, existing in mismatched:
        print(f"SPECIFIER?  code {json.dumps(key, ensure_ascii=False)} vs table {json.dumps(existing, ensure_ascii=False)}")
    for path, line, expr in unknown:
        print(f"TYPE?       {path}:{line}: \\({expr}) guessed as %@")
    for key in unused:
        print(f"UNUSED      {json.dumps(key, ensure_ascii=False)}")
    bad_arguments = check_arguments(strings, plurals)
    for key, value in bad_arguments:
        print(f"ARGUMENTS   {json.dumps(key, ensure_ascii=False)} -> {json.dumps(value, ensure_ascii=False)}")
    if untranslated:
        print(f"{len(untranslated)} entries are identical to English (product names, symbols, formats):")
        for key in untranslated:
            print(f"  same      {json.dumps(key, ensure_ascii=False)}")
    if args.suspicious:
        for path, line, raw in suspicious:
            print(f"UNLOCALIZED? {path}:{line}: {raw}")
    return 1 if missing or mismatched or bad_arguments else 0


if __name__ == "__main__":
    sys.exit(main())
