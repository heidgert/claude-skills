---
name: analyzing-appinsights-performance
description: Use when the user asks to analyze, investigate, or find performance issues in an Application Insights CSV log export — slow requests, slow SQL, or N+1 query patterns in a .NET / EF Core codebase
---

# Analyzing Application Insights Performance Logs

## Overview

A log dump from Application Insights is rich but noisy. This skill turns it into a candidate list, picks one issue **with the user**, locates the exact executing code in the current repo, and proposes a scoped fix.

**Core principle:** stay on the executing path of the one issue the user picked. Everything else is observation, not work.

## When NOT to use

- The export is not a CSV from App Insights (e.g. KQL JSON, raw `.aitrace`).
- The user wants a sweeping perf audit across many requests — this skill investigates one issue at a time.
- The repo open in cwd has no obvious match to the operations in the log (skill exits in Phase 1).

## Workflow — five phases, in order

```
1. Validate     → parse CSV, confirm repo matches operation namespace, or EXIT
2. Discover     → present ranked candidate table, STOP, wait for user pick
3. Locate       → trace endpoint FQN → controller → handler/repository
4. Propose      → prose explanation + diff if relevant, scoped to executing path
5. Regress      → AFTER user implements the fix, deep regression sweep
6. Ship         → file work item, push branch, open linked PR (Azure DevOps)
```

Do not skip phases. Do not collapse phase 2 into phase 3 by picking yourself.

## Phase 1 — Validate

1. Run the bundled parser against the CSV:
   ```
   python <skill_dir>/parser.py <csv_path>
   ```
   The parser handles multiline quoted SQL fields. Use its JSON output as the source of truth — do not Read the raw CSV for analysis. Read raw rows only when you need the original timestamp for a specific record.

2. Read `operation_namespace` from each request (e.g. `Kaskelot.External.API.Controllers.MyAssignments.MyAssignmentsQueryController.GetElectDayAssignmentContactPersons`).

3. Verify the repo in cwd matches. Glob for a `*.csproj` whose name shares the leading namespace segments (e.g. `Kaskelot.External.API.csproj`). If no match:
   > "The operation namespace `<X>` does not appear to live in this repo (cwd: `<cwd>`). Open the correct repo and run again."
   Then **exit**. Do not guess across sibling drives.

## Phase 2 — Discover candidates

For each request in the parser output, compute three signals:

| Signal | Meaning | Detection |
|--------|---------|-----------|
| **Slow request** | Total wall time exceeds threshold | `duration_ms` ≥ ~1000 ms |
| **Slow SQL** | A single dependency dominates | `dependencies[].duration_ms` ≥ ~500 ms |
| **Repeat / N+1** | Same SQL signature fires ≥ 2× in one request | `duplicate_signatures[]` from parser |
| **App-time gap** | In-process work between deps (materialization, mapping, serialization) | `app_time_gap_ms = duration_ms − deps_total_ms`; flag when gap ≥ 50% of total or ≥ 1000 ms |

Two distinctions to draw clearly:

- **N+1 loop** = small parameterised query repeated per item from a parent result set.
- **Load-the-world** = one or two unfiltered `SELECT … FROM Big WHERE-less` reads followed by client-side `FirstOrDefault`. Looks similar in totals but the fix is a `Where` clause, not a join rewrite.

Present a single ranked table to the user. Include record numbers (from parser output, not raw CSV line numbers) and the parser's normalized SQL signature truncated to ~120 chars. Then **stop and wait** for the user to pick one. Do not begin Phase 3 until they have.

Example:

```
| # | Severity | Type             | Evidence rows | Cost       | Notes
|---|----------|------------------|---------------|------------|----------------
| 1 | CRITICAL | App-time gap     | request 2     | 32023 ms   | 91% of total — likely materialization/mapping
| 2 | HIGH     | Slow + duplicate | deps 9, 13    | 2971 ms    | Same wide SELECT × 2 (load-the-world)
| 3 | LOW      | Duplicate        | deps 15, 17   | 1.68 ms    | Same TOP(1) × 2; not impactful here
```

## Phase 3 — Locate

The `operation_namespace` from the "Executing endpoint" trace is the **highest-fidelity signal**. Use it first:

1. Glob for the controller class file by name (last namespace segment before the action).
2. Open the action method. Trace each call into handlers / repositories / queries until you reach the code that produced the offending dependency. For EF Core, the SQL signature in the parser output usually maps directly to a single LINQ expression — match by table name and join shape.
3. **Quote the offending lines** with `file_path:line` so the user can navigate.

4. **Cross-check git history before drawing conclusions about "incomplete fixes."** If the offending code looks like something the codebase actively tried to prevent — e.g. a pattern that a recent commit subject addresses, or behavior that contradicts current intent — do this before continuing:
   - `git log --oneline -30 -- <file>` for each file on the executing path.
   - For any commit whose subject matches the symptom, `git show <hash>` and read the diff.
   - Read the original timestamp from the raw CSV record (parser does not expose it) and compare to the commit date — telemetry from before the fix proves nothing about current code.
   - Confirm the current state of the file matches the post-commit state.

   Only then characterize the issue. Do not call a fix "incomplete", "missing", or "regressed" without this check. A commit subject is a hypothesis; the diff is the evidence.

Stack traces (if the trace is on an exception row) override namespaces — use them when present.

## Phase 4 — Propose

Output structure:

1. **Root cause** — one paragraph, in prose. Why does the picked candidate happen? Tie back to specific records in the parser output.
2. **Fix** — prose first. If a code change is the answer, follow with a unified diff. The diff must:
   - Touch only files on the executing path you traced in Phase 3.
   - Preserve observable behavior (return shape, null handling, ordering).
   - Not refactor adjacent code "while we're here."
3. **Regression risks** — bullet list. Indexing, tracking vs no-tracking, cartesian explosion, null branches, validator behavior, anything material.
4. **Similar patterns elsewhere (observation only)** — if the same anti-pattern shows up in sibling methods/files, **mention them with `file:line`**, but do not propose changes there. Phrase as: "Flagging only — not changing per scope rule."

Do not write to any file in this phase. The user reviews the diff first.

## Before applying — branch hygiene

If the user approves the diff and asks you to apply it, **before editing any file**:

1. `git branch --show-current` to see where you are.
2. If you are not already on a `fix/<short-description>` branch dedicated to this perf issue, do not edit. Switch first:
   ```
   git checkout main
   git pull
   git checkout -b fix/<short-description>
   ```
3. `git status` should be clean before editing. Stash or commit unrelated work on its own branch first — never carry it onto the new fix branch.

Never apply a perf fix directly on `main`, and never on top of an unrelated feature branch.

## Phase 5 — Post-implementation regression sweep

When the user confirms the fix has been implemented, do a **deep** pass before claiming done:

- Find every caller of any changed method (Grep on method name).
- For each caller, confirm the new behavior is acceptable (return shape, null/empty handling, ordering, side effects).
- Check tests that cover the changed code path. If they exist, do they still cover the new behavior? If they don't exist, say so plainly.
- Run the project's typecheck/build if available. Report output.

Only after this sweep is clean: continue to Phase 6.

## Phase 6 — Ship: work item, push, linked PR (Azure DevOps)

**Only after Phase 5 has cleared** (build green, tests green or absent, callers checked). Never push or open a PR while regressions are unresolved.

These are user-visible actions affecting shared state. **Confirm with the user before running** the work-item / push / PR commands unless they have pre-authorized in this conversation.

### Look up project-specific defaults

The skill is generic; specifics live in user memory (or per-project notes). Pull these before running any command, and ask the user for anything you can't find:

| Field | Typical source |
|-------|----------------|
| Azure DevOps org URL | user memory (e.g. `preciofishbone` for Kaskelot) |
| Project name | user memory (e.g. `Kaskelot online`) |
| Work item type | user memory (e.g. `Bug` for Kaskelot perf fixes) |
| Primary body field | user memory (e.g. `Microsoft.VSTS.TCM.ReproSteps` for Kaskelot Bug in Scrum process). For PBI / Task / User Story it is usually `System.Description`. **Do not assume — `--description` writes to `System.Description`, which is not always the field rendered on the form.** Confirm by opening the work item in DevOps the first time you set up a project. |
| Default assignee | user memory or user's own email |
| PAT env var name | user memory (e.g. `AZURE_DEVOPS_PRECIO_PAT` for Kaskelot — `az login` may be on a different org) |

### Steps in order

1. **Stage and commit** the implemented diff with a one-line subject describing the fix (e.g. `Filter GetPersonElectionDayStaffingByPersonId in SQL`).

2. **Set the PAT** if `az` isn't already authenticated for this org. In PowerShell: `$env:AZURE_DEVOPS_EXT_PAT = $env:<pat-env-var-from-memory>`.

3. **Create the work item first** — the PR will link to it via `--work-items` at creation time, which is cleaner than adding it after.
   ```
   az boards work-item create \
     --org https://dev.azure.com/<org> \
     --project "<project>" \
     --type "<type>" \
     --title "<concise summary of the perf issue>" \
     --assigned-to <assignee> \
     --fields "<body-field>=<see content guidance below>" "System.State=New"
   ```
   Pass the body via `--fields "<body-field>=..."` using the field name from the lookup table (not `--description`), so it lands on the field the form actually renders. For non-ASCII characters (Swedish å/ä/ö, etc.) az CLI on Windows can mangle `--fields` arguments via console codepage; if you find characters dropped, fall back to a direct REST `PATCH` call with a JSON-Patch body — `Invoke-RestMethod` handles UTF-8 cleanly.
   ⚠️ **Pass `--description` HTML on a single line.** The az CLI silently truncates multi-line `--description` arguments at the first whitespace boundary (PowerShell here-strings, bash heredocs alike). It returns a successful-looking JSON with the new work item id; the truncation is invisible until you `az boards work-item show`. HTML does not need newlines between tags — concatenate. After running create/update, verify with `az boards work-item show` that `System.Description.Length` is roughly what you sent; if it is much shorter, you got truncated and must re-apply.

   **Work item title and description — plain-language for non-developers.** Product owners and testers read work items. Write for them; keep developer-language detail in an optional technical section at the bottom of the description.

   **Title** — describe the user-visible problem in **present tense** (a problem statement, not the fix). No endpoint paths, SQL identifiers, class/method names, or index names. Don't mix the resolution into the title — the title is what the work item *is about*; how it was fixed lives in the description and the linked PR.
   - ❌ `POST InterestCommand/SendApplicationForm — 30s on FaltData duplicate-check (missing covering index)` (developer language)
   - ❌ `Slow interest-form submission — duplicate-check sped up via DB index` (past tense, describes the fix)
   - ✅ `Interest form submission is slow because of the duplicate-check query`

   **Description** — in this order:
   1. **User experience** — one sentence on what users saw ("Submitting an interest form was taking around 30 seconds.").
   2. **What changed** — one sentence in observable terms ("Database tuning makes the duplicate-application check nearly instant.").
   3. **How it was found** — App Insights, request date.
   4. **Technical detail** (optional bottom section, kept for the devs who'll triage future related issues) — operation namespace, key durations from the parser (total, deps, app-time gap), evidence rows (parser indices), offending SQL signature (truncated to ~200 chars), one-line summary of the code change.

   Capture the returned work item ID.

4. **Push the branch.**
   ```
   git push -u origin fix/<short-description>
   ```

5. **Open the PR**, linking the work item by ID.
   ```
   az repos pr create \
     --org https://dev.azure.com/<org> \
     --project "<project>" \
     --source-branch fix/<short-description> \
     --target-branch main \
     --title "<one-line summary>" \
     --description "<diff rationale + reference to work item #<id>>" \
     --work-items <id>
   ```
   **PR description content** (the *diff rationale*, not the full analysis): what the diff changes and why, regression risks worth a reviewer's eye, and a link to the work item. The deep analysis lives on the work item — the PR description should be readable without it but link there for context.

6. **Report both URLs** (work item, PR) back to the user.

## Scope discipline (read this twice)

The user picked **one** candidate. That candidate has **one** executing path. Stay on it.

| Temptation | Do this instead |
|------------|-----------------|
| "While I'm here, the validator also calls this expensive method twice — let me dedupe" | Mention as observation. Do not change unless user picked the duplication itself. |
| "This whole repository pattern would be cleaner with projections" | Out of scope. Note once if directly relevant; move on. |
| "Five other methods have the same anti-pattern" | List them with `file:line`. Do not edit them. |
| "I can pick a more impactful candidate than the one the user named" | No. The user picked. Work that one. |

## Common mistakes

- **Reading the raw CSV with line tools.** Multiline quoted SQL breaks `grep`/line counting. Always use `parser.py`.
- **Confusing record numbers with raw CSV line numbers.** The parser's `row` field is the CSV record index (a single record may span 10+ raw lines). When citing the user, say "record" and use parser indices throughout — or quote the timestamp instead.
- **Picking the candidate yourself.** The user said b: present, then they pick. Do not collapse.
- **Skipping the repo-match check.** If `Kaskelot.External.*` operations are running but cwd is `D:/SomeOther/Repo`, every file path you produce will be wrong. Verify or exit.
- **Treating the app-time gap as background.** A 32-second gap with 3 seconds of SQL is the headline, not a footnote. Materialization and AutoMapper on huge unfiltered result sets routinely dominate.
- **Claiming done after the diff.** The fix isn't done until Phase 5 has run on the real implemented code.
- **Calling a fix "incomplete" without `git show`.** If you reference a recent commit, you must have read its diff and confirmed the current state of the executing path. A commit subject is a hypothesis; the diff is the evidence. Compare the request timestamp against the commit date — telemetry predating the commit proves nothing.
- **Pushing or opening a PR before Phase 5 has cleared.** A PR with broken tests / build wastes reviewer time and clutters the queue.
- **Opening the PR before the work item exists.** `az repos pr create --work-items <id>` links at creation time. If you create the PR first, you have to manually link afterward and people forget.
- **Skipping the work item.** Even for a small perf fix, the work item is where the *what + why* lives — the PR description is for diff rationale only.
- **Writing the work item in developer language.** Endpoint paths, SQL identifiers, class names, and index names belong in the description's optional technical-detail section — never in the title or the user-facing summary. Product owners and testers read work items; write for them.
- **Multi-line `--description` to `az boards work-item create/update`.** Silently truncated at the first whitespace boundary; az returns a success response with the work item id, so the truncation is invisible until you re-fetch. Always concatenate the HTML to a single line before passing.
- **Writing the body to `System.Description` on a Bug.** In Scrum / Agile process templates the Bug form renders `Microsoft.VSTS.TCM.ReproSteps`, not `System.Description`. Body content on `System.Description` is invisible on the form. Use `--fields "<body-field>=..."` with the field from the project lookup, not `--description`.

## Red flags — STOP

- About to edit a file the parser output didn't lead you to → wrong path.
- About to propose a refactor across multiple unrelated files → out of scope.
- Couldn't match the operation namespace to anything in cwd but proceeded anyway → repo mismatch.
- About to report "fixed" without running Phase 5 → premature completion.
- About to write "this should have been fixed by commit X" without having run `git show X` and confirmed the executing path's current state → STOP. Read the diff first.
- About to apply a diff while on `main` or on an unrelated feature/fix branch → STOP. Create a `fix/<short-description>` branch off `main` first.
- About to push or open a PR while Phase 5 has not cleared → STOP.
- About to run `az repos pr create` without a `--work-items <id>` argument → STOP. Create the work item first and link it at PR creation.
- About to put SQL identifiers, class/method names, or index names in the work item *title* → STOP. Title is for product owners and testers; rewrite in plain language.
- About to write the work item title in past tense or describe the fix in it (e.g. "X was slow", "Sped up Y") → STOP. Titles are present-tense problem statements ("X is slow", "Y returns no result when …"). The fix belongs in the description.
- About to pass a here-string / heredoc as `--description` to `az boards work-item create` or `az boards work-item update` → STOP. Concatenate to a single line first, or you will silently lose everything past the first whitespace boundary.

## Files in this skill

- `parser.py` — CSV parser. Run with `python parser.py <csv_path>`. Outputs JSON with per-request candidates, normalized SQL signatures, duplicate counts, and app-time gap. The skill workflow assumes you use this output rather than reading raw CSV.
