#!/usr/bin/env python3
"""Offline coverage, JSON example, and local-link checks for docs/api.

This deliberately does not issue requests or claim to validate server schemas.
Run from any working directory: python3 scripts/check_api_docs.py
"""

import json
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]
API_DOCS = ROOT / "docs" / "api"
MODULES = (
    "AUTH.md", "ACCOUNT.md", "COMMUNITY.md", "GAME.md", "DUEL.md",
    "COMMERCE.md", "CONTENT.md", "RESOURCES.md",
)
OPERATION = re.compile(r"^### (GET|POST|PUT|DELETE|PATCH) (\S+)\s*$", re.MULTILINE)
CATALOG_ROUTE = re.compile(
    r'\.init\("[^"\n]+", "[^"\n]+", "([^"\n]+)"'
    r'(?:,\s*\.(get|post|put|delete))?'
)
LITERAL_PATH = re.compile(r'path:\s*"((?:\\.|[^"\\])*)"')
EXTRA_OPERATIONS = {
    ("GET", "/repos/Ccat-Q/XDYL-Updater2-IOS/releases/latest"),
    ("GET", "/user/avatar/{filename}"),
    ("GET", "{download_url}"),
    ("GET", "/webadmin"),
}


def matches_swift_path(literal, documented):
    # Swift interpolation can contain inner double-quoted expressions; those
    # complex dynamic expressions are not a static route and are skipped below.
    parts = re.split(r"\\\([^)]*\)", literal)
    pattern = r"[^/]+".join(re.escape(part) for part in parts)
    return re.fullmatch(pattern, documented) is not None


def markdown_anchors(text):
    anchors = set()
    counts = {}
    for heading in re.findall(r"^#{1,6}\s+(.+)$", text, re.MULTILINE):
        slug = re.sub(r"[^\w\- ]", "", heading.lower()).replace(" ", "-")
        count = counts.get(slug, 0)
        counts[slug] = count + 1
        anchors.add(f"{slug}-{count}" if count else slug)
    return anchors


def main():
    errors = []
    developer_source = (ROOT / "StarWave/Core/DeveloperTools.swift").read_text()
    catalog = developer_source.split("static var catalog:", 1)[1].split("struct DeveloperSession", 1)[0]
    known = [((method or "get").upper(), path) for path, method in CATALOG_ROUTE.findall(catalog)]
    if not known:
        errors.append("No developer routes found; update the source extractor.")
    if len(known) != len(set(known)):
        errors.append("Duplicate method/path in developer catalog; inspect service identity.")

    documented = set()
    examples = 0
    for name in MODULES:
        path = API_DOCS / name
        if not path.is_file():
            errors.append(f"Missing module {path.relative_to(ROOT)}")
            continue
        text = path.read_text()
        headings = list(OPERATION.finditer(text))
        if not headings:
            errors.append(f"No operation headings in {name}")
        for heading in headings:
            operation = heading.group(1, 2)
            if operation in documented:
                errors.append(f"Duplicate documented operation: {operation}")
            documented.add(operation)
        for match in re.finditer(r"```json\s*\n(.*?)\n```", text, re.DOTALL):
            try:
                json.loads(match.group(1))
                examples += 1
            except json.JSONDecodeError as error:
                line = text[:match.start()].count("\n") + 1
                errors.append(f"Invalid JSON in {name}:{line}: {error}")

    for operation in sorted(set(known) | EXTRA_OPERATIONS):
        if operation not in documented:
            errors.append(f"Undocumented operation: {operation[0]} {operation[1]}")
    for operation in sorted(documented - set(known) - EXTRA_OPERATIONS):
        errors.append(f"Unclassified operation; update coverage scope: {operation}")

    paths = {path for _, path in documented}
    literal_count = 0
    for source in (ROOT / "StarWave").rglob("*.swift"):
        # DeveloperTools custom paths are arbitrary by design, not a finite API.
        if source.name == "DeveloperTools.swift":
            continue
        for literal in LITERAL_PATH.findall(source.read_text()):
            if not literal.startswith("/") or '\\(' in literal and not literal.endswith(")"):
                continue
            literal_count += 1
            if not any(matches_swift_path(literal, path) for path in paths):
                errors.append(f"Undocumented source path in {source.relative_to(ROOT)}: {literal}")

    # Include surrounding docs/README to catch links broken by the migration.
    checked_links = 0
    for source in [ROOT / "README.md", *sorted((ROOT / "docs").rglob("*.md"))]:
        text = source.read_text()
        prose = re.sub(r"```.*?```", "", text, flags=re.DOTALL)
        prose = re.sub(r"`[^`\n]+`", "", prose)
        for raw in re.findall(r"\[[^\]\n]*\]\(([^)\n]+)\)", prose):
            raw = raw.strip().strip("<>")
            parsed = urlsplit(raw)
            if parsed.scheme or parsed.netloc or raw.startswith("/"):
                continue
            target = (source.parent / unquote(parsed.path)).resolve() if parsed.path else source
            checked_links += 1
            if not target.exists():
                errors.append(f"Broken local link in {source.relative_to(ROOT)}: {raw}")
            elif parsed.fragment and target.suffix == ".md":
                if unquote(parsed.fragment) not in markdown_anchors(target.read_text()):
                    errors.append(f"Missing Markdown anchor in {source.relative_to(ROOT)}: {raw}")
        for retired in ("docs/API_COMPATIBILITY.md", "docs/LEADERBOARD_SOURCES_2026-10-18.md", "API_REFERENCE.md"):
            if retired in text:
                errors.append(f"Retired API document path in {source.relative_to(ROOT)}: {retired}")

    # Also validate JSON examples in the common README, not only endpoint pages.
    for match in re.finditer(r"```json\s*\n(.*?)\n```", (API_DOCS / "README.md").read_text(), re.DOTALL):
        try:
            json.loads(match.group(1)); examples += 1
        except json.JSONDecodeError as error:
            errors.append(f"Invalid JSON in api/README.md: {error}")

    if errors:
        print("API documentation check failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(f"PASS: {len(known)} catalog operations + {len(EXTRA_OPERATIONS)} extra operations documented.")
    print(f"PASS: {literal_count} literal business request paths covered.")
    print(f"PASS: {examples} JSON examples valid; {checked_links} relative links/anchors resolved.")
    print("Offline checks only: no server schema, authentication, or live endpoint validation.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
