# WindowsBuildTracker

Authoritative, self-updating database of Windows cumulative-update build numbers, plus a NinjaRMM script that uses it to report patch-compliance into custom fields.

## What's in here

| File | Purpose |
|---|---|
| `windows-builds.json` | Machine-readable build database. Refreshed weekly from learn.microsoft.com/windows/release-health. |
| `Get-WindowsCumulativeUpdate.ps1` | PowerShell script to deploy via NinjaRMM. Resolves the installed build against the database and writes 5 custom fields. |
| `scripts/refresh-builds.py` | Scraper that rebuilds `windows-builds.json` from Microsoft's release-health pages. |
| `.github/workflows/refresh-builds.yml` | GitHub Action that runs the scraper weekly and commits changes. |
| `tests/WindowsPatchCheck.Tests.ps1` | Pester tests for the PowerShell script's pure functions. |

## How it works

1. **GitHub Action** runs every Wednesday 06:00 UTC (day after Patch Tuesday), scrapes Microsoft's release-health pages (Win10, Win11, Windows Server), writes `windows-builds.json`, commits if there's a diff. On scraper failure it opens a `scraper-failure` issue.
2. **Ninja script** fetches `https://raw.githubusercontent.com/bm2025bm/WindowsBuildTracker/main/windows-builds.json` each run (cached 24h at `%ProgramData%\WindowsPatchCheck\builds.json`), resolves the installed build, and writes status into NinjaRMM custom fields.
3. If the network fetch and cache both fail, the script falls back to an embedded subset of recent builds (271 entries covering active families from 2024 onwards). The embedded subset is refreshed manually when the script is re-released.

## NinjaRMM custom fields

Create these before deploying the script. All are device-level custom fields.

| Name | Type | Meaning |
|---|---|---|
| `windowscumulativeupdatestatus` | Text | `OK` \| `UnknownBuild` \| `Insider` \| `NetworkError` \| `ScriptError` |
| `windowscumulativeupdatedate` | Text | `YYYY.MM` (with `-Preview` / `-OOB` suffix when applicable). Empty unless status=OK. |
| `windowscumulativeupdatedifference` | Integer | Months behind latest Standard patch for this build family (≤0). Empty unless status=OK. |
| `windowscumulativeupdateversion` | Text | Full build number, e.g. `26100.6899`. Always written. |
| `windowscumulativeupdatedatacollected` | Date/Time | Unix timestamp of the last run. Always written. |

**Invariant**: The `date` and `difference` fields contain either valid data or are empty. They never contain sentinel strings like `"Error"`. Build dashboards to filter on `status = OK` before computing fleet compliance.

## "Months behind" semantics

The script compares the installed build's release month against the **latest Standard cumulative update available for that build family** in `windows-builds.json` — not against today's calendar month. This means a machine that's on the most recent Patch Tuesday will always show `0`, and the number won't drift to `-1` at the start of every month.

Preview and OOB updates are **not** used when computing "latest" — only Standard (Patch Tuesday B-week) updates count.

## Deploying to NinjaRMM

1. In NinjaRMM, create the 5 custom fields listed above.
2. Add `Get-WindowsCumulativeUpdate.ps1` as a new script in the Automation library.
3. Schedule it to run daily (or however often you want the freshness data updated).
4. Build a dashboard widget filtering on `status = OK AND difference <= -2` to surface non-compliant devices.

## Running the scraper locally

```bash
pip install requests beautifulsoup4
python scripts/refresh-builds.py
```

Writes to `windows-builds.json`. Exits non-zero if any page returns fewer builds than the minimum expected (protects against silent layout changes).

## Running the tests

```powershell
Install-Module Pester -Force -Scope CurrentUser
Invoke-Pester -Path ./tests/WindowsPatchCheck.Tests.ps1 -Output Detailed
```

Tests only the pure functions (`Resolve-BuildInfo`, `Get-LatestForFamily`, `Get-MonthsBehind`, `Format-DateString`) against a frozen sample database. No network, no Ninja, no registry.

## Data source

`learn.microsoft.com/windows/release-health` — Microsoft's official release-health pages:

- [Windows 10](https://learn.microsoft.com/en-us/windows/release-health/release-information) (covers 14393, 17763, 19044, 19045, and older)
- [Windows 11](https://learn.microsoft.com/en-us/windows/release-health/windows11-release-information) (covers 22000, 22621, 22631, 26100, 26200)
- [Windows Server](https://learn.microsoft.com/en-us/windows/release-health/windows-server-release-info) (covers 20348, 26100)

These pages are not a documented public API but the HTML table structure has been stable for years. If Microsoft changes the layout, the scraper will fail the minimum-count check, the workflow will fail, and a GitHub issue will be opened automatically.

## License

MIT
