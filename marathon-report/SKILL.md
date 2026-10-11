---
name: marathon-report
description: Use when the user asks for the monthly Marathon report or how many production releases were made last month (or in a given month) across Troman, Kaskelot and Mobilise — runs a deterministic PowerShell script against the Azure DevOps release APIs of all three tenants and applies the agreed counting rules, so the number is the same every time
---

# Marathon monthly report: releases

Marathon companies all report one KPI each month: the **total number of production
releases**. This skill produces that number for Troman, Kaskelot and Mobilise, plus a
per-platform breakdown so the total can be checked.

Never count releases by hand or re-derive the rules. Run the script and relay its output.

## Run

```powershell
pwsh -NoProfile -File ~/.claude/skills/marathon-report/marathon-releases.ps1 -Month 2026-09
```

| Parameter | Meaning |
|---|---|
| `-Month yyyy-MM` | Month to report. Default: the previous month (Stockholm time). |
| `-Json <path>` | Also write the report data as JSON. |
| `-Config <path>` | Use another config (default: `marathon-releases.config.json` next to the script). |

Required environment variables (PATs with **Release (Read)** scope):

| Org | Env var | Platform |
|---|---|---|
| troman-ab | `AZURE_DEVOPS_EXT_PAT` | Troman |
| preciofishbone | `AZURE_DEVOPS_PRECIO_PAT` | Kaskelot (production still runs in the Precio tenant) |
| mobilise | `AZURE_DEVOPS_MOBILISE` | Mobilise (Classic + NG) |

## Relaying the result

1. Lead with the total: "Total releases for <month>: N". Then show the platform table.
2. Relay **every warning** as-is:
   - **INCOMPLETE / FAILED to read …**: the total is not final. Say which org failed and why (often an expired PAT) and do not present the number as the KPI.
   - **Not final yet**: the run is within 24 h of month end. Suggest re-running after the time given.
   - **New stage '…'**: ask the user whether it is a customer tenant or internal, add it to `knownCustomerStages` or `excludeStages` for that definition in the config, commit, and re-run.
   - **Unknown release definition '…'**: ask the user, then add it to `definitions` (with `includeStages`, or `excludeStages` + `knownCustomerStages`, plus a `label`) or to `ignoreDefinitions`, commit, and re-run.
3. Only show the detail and "Not counted" sections if the user asks or a number looks surprising.

## Counting rules (summary)

The full rules and the reasoning behind them are in
`D:/Troman/docs/superpowers/specs/2026-10-09-marathon-release-report-design.md`.

1. Only classic Release pipeline deploys with status `succeeded` or `partiallySucceeded` count. Retries count once.
2. Production = `Prod` (Troman) or `Production` (Kaskelot). For Mobilise every customer-tenant stage is production and internal stages (`val`, `valg`, `UppsalaDev`, `dntdev`, `Demo`, `Demo live`, `Troman`, …) are excluded.
3. A release replaced on **every** stage it reached by a newer release of the same definition within **24 h** is folded into the newer one.
4. A release counts in the month (Stockholm time) of its **first** production deploy, and only once.
5. Within a platform, releases whose first deploys are within 24 h of the group's first release count as **one** release. This covers Troman components shipped together, Kaskelot Internal + External, and Mobilise Classic + NG.
6. KPI = sum of the platform counts. Releases of different platforms never merge.

## Changing the rules

All rules live in `marathon-releases.config.json` (windows, statuses, platforms, stage lists).
Change the config, not the script, and keep the spec in sync. After any change run the tests:

```powershell
pwsh -NoProfile -Command "Import-Module Pester -MinimumVersion 5.0; Invoke-Pester -Path ~/.claude/skills/marathon-report/marathon-releases.Tests.ps1"
```
