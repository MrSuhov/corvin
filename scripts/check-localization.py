#!/usr/bin/env python3
"""Guard the localization catalogues against drift.

Localization in this repo has no history of its own: the keys arrived in the
initial commit and every feature since wrote user-facing text straight into the
source. This runs in CI so that stops happening.

    ./scripts/check-localization.py          # errors fail the build
    ./scripts/check-localization.py --report # per-language coverage, no failure

Checks:
  1. key parity across every .lproj in a catalogue family
  2. format-specifier parity per key — the only localization bug class that crashes
  3. .stringsdict completeness, and no key defined in both .strings and .stringsdict
  4. keys used in code but not defined (error) / defined but unused (warning)
  5. user-facing string literals that never reach a catalogue
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE_ROOTS = ["Shared", "macOS", "iOS", "CorvinKeyboard"]
ALLOWLIST = ROOT / "scripts/localization-allowlist.txt"

# Catalogue families. Each is checked for internal parity; they are separate
# bundles, so keys are deliberately not compared across families.
FAMILIES = {
    "app": ROOT / "Shared/Resources",
    "keyboard": ROOT / "CorvinKeyboard/Resources",
}

# Keys built at runtime by prefix, so "unused" cannot be an error for them.
DYNAMIC_PREFIXES = ("models.quality.", "keyboard.language.", "engine.", "decoder.",
                    "settings.tab.", "test.")

SPECIFIER = re.compile(
    r"%(?:\d+\$)?[-+ #0]*(?:\*|\d+)?(?:\.(?:\*|\d+))?(?:hh|h|ll|l|L|z|j|t|q)?([@dDiuUxXoOfFeEgGcCsSpaA%])"
)

errors: list = []
warnings: list = []


def fail(msg):
    errors.append(msg)


def warn(msg):
    warnings.append(msg)


def read_plist(path: pathlib.Path) -> dict:
    """Parse via plutil: a stray quote or missing semicolon truncates a .strings
    file silently at runtime, and that is worth catching here rather than in the
    app."""
    try:
        out = subprocess.run(["plutil", "-convert", "json", "-o", "-", str(path)],
                             capture_output=True, text=True, check=True).stdout
        return json.loads(out)
    except subprocess.CalledProcessError as e:
        fail(f"{path.relative_to(ROOT)}: does not parse — {e.stderr.strip()}")
        return {}


def specifiers(value: str) -> list:
    return [m.group(1) for m in SPECIFIER.finditer(value) if m.group(1) != "%"]


# --- 1..3: catalogue integrity -------------------------------------------------

def check_family(name: str, base: pathlib.Path) -> dict:
    langs = sorted(p.name[:-6] for p in base.glob("*.lproj"))
    if not langs:
        return {}
    coverage = {}

    for table in ("Localizable.strings", "InfoPlist.strings", "AppShortcuts.strings"):
        present = {l: base / f"{l}.lproj/{table}" for l in langs
                   if (base / f"{l}.lproj/{table}").exists()}
        if not present:
            continue
        missing_files = set(langs) - set(present)
        if missing_files:
            fail(f"[{name}] {table} missing for: {', '.join(sorted(missing_files))}")
        data = {l: read_plist(p) for l, p in present.items()}
        reference = "en" if "en" in data else sorted(data)[0]
        ref_keys = set(data[reference])
        for lang, d in data.items():
            missing = ref_keys - set(d)
            extra = set(d) - ref_keys
            for k in sorted(missing):
                fail(f"[{name}] {table}: '{k}' missing in {lang}")
            for k in sorted(extra):
                fail(f"[{name}] {table}: '{k}' in {lang} but not in {reference}")
            # Check 2 — a %@ where the code passes an Int crashes at runtime.
            for k in sorted(ref_keys & set(d)):
                if specifiers(data[reference][k]) != specifiers(d[k]):
                    fail(f"[{name}] {table}: '{k}' format specifiers differ between "
                         f"{reference} ({specifiers(data[reference][k])}) and "
                         f"{lang} ({specifiers(d[k])})")
        if table == "Localizable.strings":
            coverage = {l: len(d) for l, d in data.items()}
            coverage["_keys"] = ref_keys

    # Check 3 — plural tables
    dicts = {l: read_plist(base / f"{l}.lproj/Localizable.stringsdict")
             for l in langs if (base / f"{l}.lproj/Localizable.stringsdict").exists()}
    if dicts:
        if set(dicts) != set(langs):
            fail(f"[{name}] Localizable.stringsdict missing for: "
                 f"{', '.join(sorted(set(langs) - set(dicts)))}")
        ref = set(next(iter(dicts.values())))
        required = {"ru": {"one", "few", "many", "other"}}
        for lang, d in dicts.items():
            if set(d) != ref:
                fail(f"[{name}] stringsdict keys differ in {lang}: {sorted(set(d) ^ ref)}")
            need = required.get(lang, {"one", "other"})
            for key, spec in d.items():
                cats = {c for v in spec.values() if isinstance(v, dict) for c in v
                        if c not in ("NSStringFormatSpecTypeKey", "NSStringFormatValueTypeKey")}
                if not need <= cats:
                    fail(f"[{name}] stringsdict '{key}' in {lang} lacks plural "
                         f"categories: {sorted(need - cats)}")
        strings_keys = coverage.get("_keys", set())
        for key in sorted(ref & strings_keys):
            fail(f"[{name}] '{key}' is in both Localizable.strings and .stringsdict — "
                 f"the stringsdict wins silently, so the .strings entry is a lie")
        coverage.setdefault("_keys", set()).update(ref)

    return coverage


# --- source scanning -----------------------------------------------------------

BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.S)
LINE_COMMENT = re.compile(r"//[^\n]*")
STRING_LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
INTERPOLATION = re.compile(r"\\\([^)]*\)")

USED_KEY = re.compile(r'"([a-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+)"\s*\.localized')
USED_MESSAGE = re.compile(r'LocalizedMessage\(\s*"([^"]+)"')
USED_RESOURCE = re.compile(r'LocalizedStringResource\s*=\s*"([^"]+)"|IntentDescription\(\s*"([^"]+)"|shortTitle:\s*"([^"]+)"')

UI_CALLS = (
    "Text", "Button", "Label", "Picker", "Toggle", "TextField", "SecureField",
    "Section", "Link", "Menu", "ProgressView",
)
UI_MODIFIERS = (
    ".navigationTitle", ".navigationBarTitle", ".help", ".accessibilityLabel",
    ".confirmationDialog", ".alert", ".searchable",
)
KEY_SHAPE = re.compile(r"^[a-z][A-Za-z0-9]*(\.[A-Za-z0-9_]+)+$")
CYRILLIC = re.compile(r"[Ѐ-ӿ]")


def strip_comments(text: str) -> str:
    """Blank out comments while preserving line numbers — this repo carries a lot
    of Russian prose in comments, and without this the Cyrillic rule is useless."""
    def blank(m):
        return re.sub(r"[^\n]", " ", m.group(0))
    return LINE_COMMENT.sub(blank, BLOCK_COMMENT.sub(blank, text))


def load_allowlist():
    """Returns (path prefixes, literal substrings). A `::` entry exempts one
    literal rather than a whole file, which is what most exemptions actually
    need."""
    entries = []
    if not ALLOWLIST.exists():
        return entries
    for n, raw in enumerate(ALLOWLIST.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        # A reason is mandatory: without it the allowlist becomes a dumping ground.
        if "# reason:" not in line:
            fail(f"{ALLOWLIST.name}:{n}: entry has no '# reason:' — say why it is exempt")
            continue
        entries.append(line.split("#", 1)[0].strip())
    paths = [e for e in entries if "::" not in e]
    literals = [e.split("::", 1)[1] for e in entries if "::" in e]
    return paths, literals


def scan_sources(defined_keys: set):
    allow, literal_allow = load_allowlist()
    used = set()
    for root in SOURCE_ROOTS:
        for path in sorted((ROOT / root).rglob("*.swift")):
            rel = str(path.relative_to(ROOT))
            exempt = any(rel.startswith(a.rstrip("*")) for a in allow)
            raw = path.read_text()
            code = strip_comments(raw)

            for m in USED_KEY.finditer(code):
                used.add(m.group(1))
            for m in USED_MESSAGE.finditer(code):
                used.add(m.group(1))
            for m in USED_RESOURCE.finditer(code):
                used.add(next(g for g in m.groups() if g))
            # Looser pass: keys reached through a ternary or a helper never sit
            # next to `.localized`. Only counted when the catalogue defines them,
            # so this cannot mask a typo — that is the strict pass's job.
            for m in STRING_LITERAL.finditer(code):
                if m.group(1) in defined_keys:
                    used.add(m.group(1))

            if exempt:
                continue
            for n, line in enumerate(code.split("\n"), 1):
                for m in STRING_LITERAL.finditer(line):
                    body = INTERPOLATION.sub("", m.group(1))
                    if not body.strip():
                        continue
                    # Rule 1 — Cyrillic anywhere in a literal.
                    if CYRILLIC.search(body):
                        fail(f"{rel}:{n}: hardcoded Russian literal: \"{body[:60]}\"")
                        continue
                    # Rule 2 — untranslated literal in a UI-text position.
                    before = line[:m.start()].rstrip()
                    after = line[m.end():]
                    is_ui = (any(before.endswith(c + "(") for c in UI_CALLS)
                             or any(before.endswith(mo + "(") for mo in UI_MODIFIERS)
                             or before.endswith("prompt:") or before.endswith("title:"))
                    # Two runs of letters: what is left after stripping
                    # interpolation is often just a separator (" · ", " — )%"),
                    # and flagging those trains people to ignore the linter.
                    prose = len(re.findall(r"[A-Za-z]{2,}", body)) >= 2
                    if (is_ui and prose and not after.startswith(".localized")
                            and not KEY_SHAPE.match(body)
                            and not any(a in body for a in literal_allow)):
                        fail(f"{rel}:{n}: untranslated UI literal: \"{body[:60]}\"")
    return used


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", action="store_true", help="print coverage, never fail")
    args = ap.parse_args()

    all_keys = set()
    for name, base in FAMILIES.items():
        cov = check_family(name, base)
        all_keys |= cov.pop("_keys", set())
        if args.report and cov:
            total = max(cov.values())
            line = " · ".join(f"{l} {n}/{total}" for l, n in sorted(cov.items()))
            print(f"{name}: {line}")

    used = scan_sources(all_keys)
    for key in sorted(used - all_keys):
        fail(f"key '{key}' is used in code but defined in no catalogue")
    for key in sorted(all_keys - used):
        if not key.startswith(DYNAMIC_PREFIXES):
            warn(f"key '{key}' is defined but never used")

    for w in warnings:
        print(f"warning: {w}")
    for e in errors:
        print(f"error: {e}", file=sys.stderr)

    if args.report:
        print(f"\n{len(errors)} errors, {len(warnings)} warnings")
        return 0
    if errors:
        print(f"\n{len(errors)} localization errors", file=sys.stderr)
        return 1
    print(f"localization OK — {len(all_keys)} keys, {len(warnings)} warnings")
    return 0


if __name__ == "__main__":
    sys.exit(main())
