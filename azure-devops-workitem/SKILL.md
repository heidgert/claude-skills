---
name: azure-devops-workitem
description: Use when the user asks to create or update an Azure DevOps work item (PBI, Bug, Task, User Story) — runs a deterministic PowerShell script that talks to the REST API directly, handling UTF-8 (Swedish å/ä/ö), multi-line bodies, and the correct body field per work-item type
---

# Azure DevOps Work Item (create / update)

## When to use

The user wants to create or update an Azure DevOps work item from within a repo.
Prefer this over hand-rolling `az boards` calls: the script hits the REST API directly
and is immune to the `az` CLI's known failures — multi-line body truncation, Swedish
character (å/ä/ö) mangling, and writing the body to the wrong field.

## Prerequisites

1. A `.azuredevops.json` in the repo root (or any ancestor directory). Copy
   `.azuredevops.sample.json` from this skill and edit it:
   ```json
   {
     "org": "https://dev.azure.com/<your-org>",
     "project": "<your project>",
     "patEnvVar": "AZURE_DEVOPS_PRECIO_PAT",
     "defaultType": "Bug",
     "bodyFieldByType": {
       "Bug": "Microsoft.VSTS.TCM.ReproSteps",
       "Product Backlog Item": "System.Description",
       "Task": "System.Description",
       "User Story": "System.Description"
     },
     "defaultAssignee": "you@example.com"
   }
   ```
   The file holds **no secret** — only the *name* of the env var that holds the PAT. It
   is safe to commit.
2. The PAT itself in the environment variable named by `patEnvVar`, with Work Items
   read/write scope:
   ```powershell
   $env:AZURE_DEVOPS_PRECIO_PAT = '<personal access token>'
   ```

## How to call

**Always run with `-DryRun` first** to inspect the exact request, then re-run without it
to send. The script is at `$env:USERPROFILE/.claude/skills/azure-devops-workitem/azdo-workitem.ps1`.

```powershell
$script = "$env:USERPROFILE/.claude/skills/azure-devops-workitem/azdo-workitem.ps1"

# Create (preview)
& $script -Action create -Type "Product Backlog Item" -Title "..." -Body "<p>HTML or text</p>" -DryRun
# Create (send)
& $script -Action create -Type "Product Backlog Item" -Title "..." -Body "<p>HTML or text</p>"

# Update an existing item's body and state (no -Type needed; the script looks it up)
& $script -Action update -Id 12345 -Body "..." -Fields @{ "System.State" = "Active" }
```

### Parameters

| Parameter | Notes |
|-----------|-------|
| `-Action` | `create` or `update`. Required. |
| `-Id` | Work-item id. Required for `update`. |
| `-Type` | Work-item type for `create`. Defaults to `defaultType` from config. |
| `-Title` | Required for `create`. |
| `-Body` | Body content (HTML or plain text). Routed to the **correct field for the type** (e.g. `ReproSteps` for a Bug) via `bodyFieldByType`. **Do not also set the body field in `-Fields`** — `-Body` wins and warns. |
| `-Fields` | Hashtable of any other fields by full reference name, e.g. `@{ "System.State" = "Active"; "System.Tags" = "perf" }`. |
| `-AssignedTo` | Defaults to `defaultAssignee` from config. |
| `-Org` / `-Project` / `-PatEnvVar` | Override config when needed. |
| `-ConfigPath` | Explicit config path. Defaults to searching the current dir upward for `.azuredevops.json`. |
| `-DryRun` | Build and print the request (URL + JSON-Patch body, PAT redacted) without sending. |

### Behavior notes

- **Empty string means "not provided."** Passing `-Body ""` or `-Title ""` is treated as
  *omitted*, not as "clear this field." Clearing a field to empty is not supported in this
  version.
- **On `update` with `-Body` but no `-Type`,** the script first fetches the item to learn
  its type, then resolves the right body field. You don't need to pass `-Type` on updates.
- **After a successful send**, the script re-fetches the item to verify the write landed,
  then prints `Work item <id> : <url>` and returns an object with `id`, `url`, `type`,
  `title`, `state`. A failed verification re-fetch only warns — it never fails a write that
  already succeeded.
- **Body verification warns only on gross loss (<50% of sent length).** Azure DevOps
  normalizes/re-renders HTML on store, so a modest length difference is normal and expected.
- **UTF-8 is sent as raw bytes** (no BOM), so Swedish characters survive end to end.

## Files

- `azdo-workitem.ps1` — the worker.
- `azdo-workitem.Tests.ps1` — Pester 5 unit tests (no live API). Run from the skill
  directory: `Invoke-Pester`.
- `.azuredevops.sample.json` — config template to copy into each consuming repo.
