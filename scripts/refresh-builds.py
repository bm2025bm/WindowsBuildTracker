#!/usr/bin/env python3
"""Refresh windows-builds.json from Microsoft's release-health pages.

Scrapes three pages:
  * Windows 10 (covers 10.x, 19041-19045, 14393, 17763)
  * Windows 11 (covers 22000, 22621, 22631, 26100, 26200)
  * Windows Server (covers 20348, plus Server 2025 on 26100)

All three pages use a consistent table schema:
    Servicing option | Update type | Availability date | Build | KB article

Update type codes: 'B' = Baseline (standard Patch Tuesday), 'C'/'D' = Preview,
'OOB' = Out-of-band. We classify anything else conservatively as Standard.

Exits non-zero if fewer than a minimum-expected number of builds were found on
any page (protects against silent breakage if Microsoft changes the layout).
"""
from __future__ import annotations

import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

import requests
from bs4 import BeautifulSoup

SOURCES = {
    "win10": "https://learn.microsoft.com/en-us/windows/release-health/release-information",
    "win11": "https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information",
    "server": "https://learn.microsoft.com/en-us/windows/release-health/windows-server-release-info",
}

# Minimum rows we expect to extract per source. If a page returns fewer, the
# layout probably changed and we should fail loudly rather than publish a
# truncated database.
MIN_EXPECTED = {"win10": 400, "win11": 200, "server": 200}

BUILD_RE = re.compile(r"^\d{4,5}\.\d{1,6}$")
UPDATE_TYPE_RE = re.compile(
    r"^(?P<year>\d{4})[-.](?P<month>\d{2})\s+(?P<code>OOB|[A-Z])", re.IGNORECASE
)


def classify(update_type: str) -> str:
    """Map a release-health 'Update type' string to Standard/Preview/OOB."""
    m = UPDATE_TYPE_RE.match(update_type.strip())
    if not m:
        return "Standard"
    code = m.group("code").upper()
    if code == "OOB":
        return "OOB"
    if code in ("C", "D"):
        return "Preview"
    return "Standard"


def parse_page(html: str, source_name: str) -> list[dict]:
    soup = BeautifulSoup(html, "html.parser")
    results: list[dict] = []
    for table in soup.find_all("table"):
        headers = [th.get_text(strip=True) for th in table.find_all("th")]
        if "Build" not in headers or "Availability date" not in headers:
            continue
        # Column positions can vary slightly (some tables have an extra
        # "Month"/"Type" column for Hotpatch). Resolve by header name.
        col_idx = {name: i for i, name in enumerate(headers)}
        build_col = col_idx["Build"]
        date_col = col_idx["Availability date"]
        ut_col = col_idx.get("Update type")
        kb_col = col_idx.get("KB article")
        for row in table.find_all("tr")[1:]:
            cells = [td.get_text(strip=True) for td in row.find_all(["td", "th"])]
            if len(cells) <= max(build_col, date_col):
                continue
            build = cells[build_col]
            if not BUILD_RE.match(build):
                continue
            date_str = cells[date_col]
            try:
                avail = datetime.strptime(date_str, "%Y-%m-%d")
            except ValueError:
                continue
            update_type = cells[ut_col] if ut_col is not None and ut_col < len(cells) else ""
            kb = cells[kb_col] if kb_col is not None and kb_col < len(cells) else ""
            major = int(build.split(".")[0])
            results.append(
                {
                    "build": build,
                    "major": major,
                    "year": avail.year,
                    "month": avail.month,
                    "type": classify(update_type),
                    "kb": kb,
                    "_source": source_name,
                }
            )
    return results


def dedupe(entries: Iterable[dict]) -> list[dict]:
    """Deduplicate by build number. Prefer Standard over Preview over OOB when
    the same build appears on multiple pages."""
    priority = {"Standard": 0, "Preview": 1, "OOB": 2}
    by_build: dict[str, dict] = {}
    for e in entries:
        existing = by_build.get(e["build"])
        if existing is None or priority[e["type"]] < priority[existing["type"]]:
            by_build[e["build"]] = e
    return sorted(by_build.values(), key=lambda e: (e["major"], e["build"]))


def fetch(url: str) -> str:
    resp = requests.get(url, timeout=60, headers={"User-Agent": "WindowsBuildTracker/1.0"})
    resp.raise_for_status()
    return resp.text


def main() -> int:
    all_entries: list[dict] = []
    errors: list[str] = []
    for name, url in SOURCES.items():
        try:
            html = fetch(url)
        except Exception as exc:
            errors.append(f"{name}: fetch failed: {exc}")
            continue
        entries = parse_page(html, name)
        print(f"{name}: parsed {len(entries)} build entries", file=sys.stderr)
        if len(entries) < MIN_EXPECTED[name]:
            errors.append(
                f"{name}: parsed {len(entries)} entries, expected >= {MIN_EXPECTED[name]}"
            )
        all_entries.extend(entries)

    if errors:
        print("SCRAPER FAILED:", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    deduped = dedupe(all_entries)
    # Strip the internal _source marker from the output.
    for e in deduped:
        e.pop("_source", None)

    output = {
        "updatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": "learn.microsoft.com/windows/release-health",
        "buildCount": len(deduped),
        "builds": deduped,
    }

    out_path = Path(__file__).resolve().parent.parent / "windows-builds.json"
    out_path.write_text(json.dumps(output, indent=2) + "\n")
    print(f"wrote {out_path} ({len(deduped)} builds)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
