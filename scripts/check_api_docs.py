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
# External evidence/proposals are checked separately, never counted as iOS APIs.
CHAT_V1_OPERATIONS = {
    ("GET", "/chat/ping"), ("POST", "/chat/key"),
    ("GET", "/chat/key/{username}"), ("POST", "/chat/send"),
    ("GET", "/chat/pull"), ("POST", "/chat/read"),
}
CHAT_V2_OPERATIONS = {
    ("GET", "/chat/v2/capabilities"), ("POST", "/chat/v2/session"),
    ("DELETE", "/chat/v2/session"), ("GET", "/chat/v2/devices"),
    ("POST", "/chat/v2/devices/{device_id}/keys"),
    ("DELETE", "/chat/v2/devices/{device_id}"),
    ("GET", "/chat/v2/users/{username}/keys"),
    ("POST", "/chat/v2/messages"), ("GET", "/chat/v2/sync"),
    ("POST", "/chat/v2/sync/ack"),
    ("POST", "/chat/v2/conversations/{conversation_id}/read"),
    ("POST", "/chat/v2/sync/reset"),
    ("PUT", "/chat/v2/devices/{device_id}/bark"),
    ("DELETE", "/chat/v2/devices/{device_id}/bark"),
    ("POST", "/chat/v2/devices/{device_id}/bark/test"),
    ("GET", "/chat/v2/devices/{device_id}/bark/status"),
}
CHAT_UPSTREAM_OPERATIONS = {("POST", "/push")}
CHAT_EXTENSION_OPERATIONS = {
    ("GET", "/chat/v2/me/preferences"), ("PATCH", "/chat/v2/me/preferences"),
    ("GET", "/chat/v2/blocks"), ("PUT", "/chat/v2/blocks/{subject}"),
    ("DELETE", "/chat/v2/blocks/{subject}"), ("GET", "/chat/v2/conversations"),
    ("GET", "/chat/v2/conversations/{conversation_id}/state"),
    ("PATCH", "/chat/v2/conversations/{conversation_id}/state"),
    ("POST", "/chat/v2/conversations/{conversation_id}/clear"),
    ("GET", "/chat/v2/conversations/{conversation_id}/messages"),
    ("DELETE", "/chat/v2/messages/{message_id}"),
    ("POST", "/chat/v2/messages/{message_id}/recall"),
    ("GET", "/chat/v2/devices/{device_id}/bark"),
    ("GET", "/chat/v2/history/quota"), ("GET", "/chat/v2/history/filters"),
    ("POST", "/chat/v2/history/transfers/{pack_id}/approve"),
    ("POST", "/chat/v2/history/transfers/{pack_id}/ack"),
}
for notification_base in ("me", "devices/{device_id}"):
    for conversation_scope in ("", "/conversations/{conversation_id}"):
        for method in ("GET", "PATCH"):
            CHAT_EXTENSION_OPERATIONS.add((method, f"/chat/v2/{notification_base}{conversation_scope}/notifications"))
for pack_kind in ("backups", "transfers"):
    base = f"/chat/v2/history/{pack_kind}"
    for method in ("GET", "POST"):
        CHAT_EXTENSION_OPERATIONS.add((method, base))
    for method in ("GET", "DELETE"):
        CHAT_EXTENSION_OPERATIONS.add((method, base + "/{pack_id}"))
    CHAT_EXTENSION_OPERATIONS.add(("POST", base + "/{pack_id}/complete"))
    for method in ("GET", "PUT"):
        CHAT_EXTENSION_OPERATIONS.add((method, base + "/{pack_id}/chunks/{index}"))
CHAT_ANDROID_OPERATIONS = {
    ("GET", "/chat/read"), ("GET", "/chat/v2/devices/{device_id}/legacy"),
    ("POST", "/chat/v2/devices/{device_id}/legacy"),
    ("GET", "/chat/v2/users/{username}/protocols"), ("POST", "/chat/v2/legacy/messages"),
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

    for name, expected in (
        ("CHAT_V1.md", CHAT_V1_OPERATIONS),
        ("CHAT_V2_PROPOSAL.md", CHAT_V2_OPERATIONS | CHAT_UPSTREAM_OPERATIONS),
        ("CHAT_V2_EXTENSIONS.md", CHAT_EXTENSION_OPERATIONS),
        ("ANDROID_INTEROP.md", CHAT_ANDROID_OPERATIONS),
    ):
        source = API_DOCS / name
        if not source.is_file():
            errors.append(f"Missing separate chat document: {name}")
            continue
        body = source.read_text()
        operations = [match.group(1, 2) for match in OPERATION.finditer(body)]
        if len(operations) != len(set(operations)):
            errors.append(f"Duplicate separate chat operation in {name}")
        if set(operations) != expected:
            errors.append(f"Separate chat operation scope mismatch in {name}: "
                          f"missing={expected - set(operations)}, extra={set(operations) - expected}")
        if name.startswith("CHAT_V2") and ("LOCAL IMPLEMENTED / 本地实现" not in body or "部署状态见" not in body or "未真机联调" not in body):
            errors.append("Chat V2 must distinguish implementation, deployment status and pending device validation.")
        if name == "ANDROID_INTEROP.md" and ("部署状态见" not in body or "未APK真机联调" not in body):
            errors.append("Android interop must distinguish deployment from pending APK validation.")

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

    # Check all other API pages too, including separate local backend contracts.
    additional_sources = [
        *sorted(source for source in API_DOCS.glob("*.md") if source.name not in MODULES),
        ROOT / "docs" / "CHAT_SERVER_REMEDIATION.md",
    ]
    for source in additional_sources:
        if not source.is_file():
            errors.append(f"Missing document: {source.relative_to(ROOT)}")
            continue
        for match in re.finditer(r"```json\s*\n(.*?)\n```", source.read_text(), re.DOTALL):
            try:
                json.loads(match.group(1)); examples += 1
            except json.JSONDecodeError as error:
                errors.append(f"Invalid JSON in {source.relative_to(ROOT)}: {error}")

    if errors:
        print("API documentation check failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(f"PASS: {len(known)} catalog operations + {len(EXTRA_OPERATIONS)} extra operations documented.")
    print(f"PASS: {literal_count} literal business request paths covered.")
    print(f"PASS: separate chat scope: {len(CHAT_V1_OPERATIONS)} external V1, "
          f"{len(CHAT_V2_OPERATIONS)} local V2 base, {len(CHAT_EXTENSION_OPERATIONS)} extensions, "
          f"{len(CHAT_ANDROID_OPERATIONS)} Android additions, {len(CHAT_UPSTREAM_OPERATIONS)} upstream Bark operation.")
    print(f"PASS: {examples} JSON examples valid; {checked_links} relative links/anchors resolved.")
    print("Offline checks only: no server schema, authentication, or live endpoint validation.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
