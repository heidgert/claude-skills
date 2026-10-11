<#
.SYNOPSIS
  Counts production releases for the monthly Marathon report (Troman, Kaskelot, Mobilise).
.DESCRIPTION
  Reads classic Release pipeline deployments from the Azure DevOps orgs in
  marathon-releases.config.json and applies the counting rules in
  D:/Troman/docs/superpowers/specs/2026-10-09-marathon-release-report-design.md.
#>
[CmdletBinding()]
param(
    [string]$Month,
    [string]$Json,
    [string]$Config
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-ReleaseConfig {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Config not found: $Path" }
    $cfg = Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
    # Records are keyed by definition name only, so a name in two sources would merge silently.
    $seen = @{}
    foreach ($p in @(Get-ConfigList $cfg 'platforms')) {
        foreach ($s in @(Get-ConfigList $p 'sources')) {
            foreach ($d in @(Get-ConfigList $s 'definitions')) {
                $key = ([string]$d.name).Normalize().ToLowerInvariant()
                if ($seen.ContainsKey($key)) {
                    throw "Config error: release definition '$($d.name)' is configured in more than one source. Definition names must be unique across sources."
                }
                $seen[$key] = $true
            }
        }
    }
    $cfg
}

function ConvertTo-UtcDateTime {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    if ($Value -is [datetime]) {
        # Azure DevOps times are UTC; an unspecified kind is treated as UTC, not local.
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) { return [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc) }
        return $Value.ToUniversalTime()
    }
    [datetimeoffset]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
}

function Get-MonthWindow {
    param(
        [string]$Month,
        [Parameter(Mandatory)][string]$TimeZone,
        [datetime]$Now = [datetime]::UtcNow
    )
    $tz = [TimeZoneInfo]::FindSystemTimeZoneById($TimeZone)
    if (-not $Month) {
        $localNow = [TimeZoneInfo]::ConvertTimeFromUtc((ConvertTo-UtcDateTime $Now), $tz)
        $first = [datetime]::new($localNow.Year, $localNow.Month, 1).AddMonths(-1)
    } else {
        if ($Month -notmatch '^\d{4}-(0[1-9]|1[0-2])$') { throw "Invalid -Month '$Month'. Use yyyy-MM, e.g. 2026-09." }
        $first = [datetime]::ParseExact($Month, 'yyyy-MM', [Globalization.CultureInfo]::InvariantCulture)
    }
    $startLocal = [datetime]::SpecifyKind($first, [DateTimeKind]::Unspecified)
    $endLocal = $startLocal.AddMonths(1)
    [pscustomobject]@{
        Month    = $startLocal.ToString('yyyy-MM', [Globalization.CultureInfo]::InvariantCulture)
        Label    = $startLocal.ToString('MMMM yyyy', [Globalization.CultureInfo]::InvariantCulture)
        Start    = [TimeZoneInfo]::ConvertTimeToUtc($startLocal, $tz)
        End      = [TimeZoneInfo]::ConvertTimeToUtc($endLocal, $tz)
        TimeZone = $tz
    }
}

function Get-ConfigList {
    # Returns a config list property, or nothing when it is missing (StrictMode-safe).
    param($Object, [string]$Name)
    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name -and $null -ne $Object.$Name) {
        return @($Object.$Name)
    }
    return @()
}

function Test-NameInList {
    # Case-insensitive match that also ignores Unicode normalization (å as one or two code points).
    param([string]$Name, [object[]]$List = @())
    $n = $Name.Normalize()
    foreach ($x in $List) {
        if ([string]::Equals(([string]$x).Normalize(), $n, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-StageClass {
    param([Parameter(Mandatory)]$Definition, [Parameter(Mandatory)][string]$Stage)
    if ($Definition.PSObject.Properties.Name -contains 'includeStages') {
        if (Test-NameInList -Name $Stage -List @(Get-ConfigList $Definition 'includeStages')) { return 'production' }
        if (Test-NameInList -Name $Stage -List @(Get-ConfigList $Definition 'preprodStages')) { return 'preprod' }
        return 'unclassified'
    }
    if (Test-NameInList -Name $Stage -List @(Get-ConfigList $Definition 'excludeStages')) { return 'excluded' }
    if (Test-NameInList -Name $Stage -List @(Get-ConfigList $Definition 'knownCustomerStages')) { return 'production' }
    return 'new'
}

function Select-ProductionDeploys {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Deployments,
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][string]$Platform,
        [Parameter(Mandatory)][string[]]$CountedStatuses,
        [Parameter(Mandatory)][datetime]$WindowStart,
        [Parameter(Mandatory)][datetime]$WindowEnd
    )
    $defsByName = @{}
    foreach ($def in @(Get-ConfigList $Source 'definitions')) { $defsByName[$def.name] = $def }
    $ignore = @(Get-ConfigList $Source 'ignoreDefinitions')
    $records = @{}
    $excluded = @{}
    $warned = @{}
    $warnings = [System.Collections.Generic.List[string]]::new()

    foreach ($d in $Deployments) {
        if ($CountedStatuses -notcontains $d.deploymentStatus) { continue }
        $time = ConvertTo-UtcDateTime $d.completedOn
        if ($null -eq $time) { continue }
        $defName = [string]$d.releaseDefinition.name
        $stage = [string]$d.releaseEnvironment.name
        $inMonth = $time -ge $WindowStart -and $time -lt $WindowEnd

        $def = $defsByName[$defName]
        if ($null -eq $def) {
            if (-not (Test-NameInList -Name $defName -List $ignore) -and $inMonth -and -not $warned["def|$defName"]) {
                $warned["def|$defName"] = $true
                $warnings.Add("Unknown release definition '$defName' in $($Source.org)/$($Source.project) had successful deploys this month; not counted. Add it to 'definitions' or 'ignoreDefinitions' in the config.")
            }
            continue
        }

        $class = Get-StageClass -Definition $def -Stage $stage
        if ($class -eq 'preprod') { continue }
        if ($class -eq 'unclassified') {
            if ($inMonth -and -not $warned["stage|$defName|$stage"]) {
                $warned["stage|$defName|$stage"] = $true
                $warnings.Add("Unknown stage '$stage' in '$defName' ($Platform) is not counted. Classify it in the config: add it to 'includeStages' or 'preprodStages'.")
            }
            continue
        }
        if ($class -eq 'new' -and $inMonth -and -not $warned["stage|$defName|$stage"]) {
            $warned["stage|$defName|$stage"] = $true
            $warnings.Add("New stage '$stage' in '$defName' ($Platform) is counted as a customer tenant. Classify it in the config: add it to 'knownCustomerStages' or 'excludeStages'.")
        }

        $label = $defName
        if ($def.PSObject.Properties.Name -contains 'label' -and $def.label) { $label = $def.label }
        $rec = [pscustomobject]@{
            Platform = $Platform; Definition = $defName; Label = $label
            ReleaseId = [int]$d.release.id; ReleaseName = [string]$d.release.name
            Stage = $stage; Time = $time; Status = [string]$d.deploymentStatus
        }
        $target = if ($class -eq 'excluded') { $excluded } else { $records }
        $key = "$defName|$($rec.ReleaseId)|$stage"
        if (-not $target.ContainsKey($key) -or $time -lt $target[$key].Time) { $target[$key] = $rec }
    }

    [pscustomobject]@{
        Records  = @($records.Values)
        Excluded = @($excluded.Values)
        Warnings = @($warnings)
    }
}

function Find-SupersededReleases {
    # A release is superseded when, on every stage it reached, a newer release of the same
    # definition was deployed within the window after it. Returns "Definition|ReleaseId" -> superseding record.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records,
        [Parameter(Mandatory)][double]$WindowHours
    )
    $window = [timespan]::FromHours($WindowHours)
    $result = @{}
    foreach ($defGroup in ($Records | Group-Object Definition)) {
        foreach ($relGroup in ($defGroup.Group | Group-Object ReleaseId)) {
            $by = $null
            $all = $true
            foreach ($r in $relGroup.Group) {
                $newer = $defGroup.Group | Where-Object {
                    $_.Stage -eq $r.Stage -and $_.ReleaseId -gt $r.ReleaseId -and
                    $_.Time -gt $r.Time -and ($_.Time - $r.Time) -le $window
                } | Sort-Object Time | Select-Object -First 1
                if ($null -eq $newer) { $all = $false; break }
                if ($null -eq $by -or $newer.ReleaseId -gt $by.ReleaseId) { $by = $newer }
            }
            if ($all) { $result["$($relGroup.Group[0].Definition)|$($relGroup.Group[0].ReleaseId)"] = $by }
        }
    }
    $result
}

function Format-LocalDate {
    param([Parameter(Mandatory)][datetime]$Utc, [Parameter(Mandatory)]$TimeZone)
    [TimeZoneInfo]::ConvertTimeFromUtc((ConvertTo-UtcDateTime $Utc), $TimeZone).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-CountedReleases {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records,
        [object[]]$Excluded = @(),
        [hashtable]$Superseded = @{},
        [Parameter(Mandatory)][datetime]$WindowStart,
        [Parameter(Mandatory)][datetime]$WindowEnd,
        [Parameter(Mandatory)]$TimeZone
    )
    $counted = [System.Collections.Generic.List[object]]::new()
    $notCounted = [System.Collections.Generic.List[object]]::new()
    $prodKeys = @{}

    foreach ($g in ($Records | Group-Object Definition, ReleaseId)) {
        $recs = @($g.Group | Sort-Object Time)
        $first = $recs[0]
        $key = "$($first.Definition)|$($first.ReleaseId)"
        $prodKeys[$key] = $true
        $firstInMonth = $first.Time -ge $WindowStart -and $first.Time -lt $WindowEnd

        if ($Superseded.ContainsKey($key)) {
            if ($firstInMonth) {
                $by = $Superseded[$key]
                $notCounted.Add([pscustomobject]@{
                    Platform = $first.Platform; Label = $first.Label; ReleaseName = $first.ReleaseName
                    Reason = "folded into $($by.Label) $($by.ReleaseName) (replaced on every stage within the supersede window)"
                })
            }
            continue
        }
        if ($first.Time -lt $WindowStart) {
            $deployedInMonth = @($recs | Where-Object { $_.Time -ge $WindowStart -and $_.Time -lt $WindowEnd }).Count -gt 0
            if ($deployedInMonth) {
                $notCounted.Add([pscustomobject]@{
                    Platform = $first.Platform; Label = $first.Label; ReleaseName = $first.ReleaseName
                    Reason = "first production deploy $(Format-LocalDate -Utc $first.Time -TimeZone $TimeZone) was in an earlier month"
                })
            }
            continue
        }
        if (-not $firstInMonth) { continue }   # first deploy after the month (look-ahead data)

        $counted.Add([pscustomobject]@{
            Platform = $first.Platform; Definition = $first.Definition; Label = $first.Label
            ReleaseId = $first.ReleaseId; ReleaseName = $first.ReleaseName
            FirstDeploy = $first.Time
            Stages = @($recs | ForEach-Object Stage)
            Partial = @($recs | Where-Object Status -eq 'partiallySucceeded').Count -gt 0
        })
    }

    $excludedInMonth = @($Excluded | Where-Object { $_.Time -ge $WindowStart -and $_.Time -lt $WindowEnd })
    foreach ($g in ($excludedInMonth | Group-Object Definition, ReleaseId)) {
        $f = $g.Group[0]
        if ($prodKeys.ContainsKey("$($f.Definition)|$($f.ReleaseId)")) { continue }
        $stages = @($g.Group | ForEach-Object Stage | Sort-Object -Unique) -join ', '
        $notCounted.Add([pscustomobject]@{
            Platform = $f.Platform; Label = $f.Label; ReleaseName = $f.ReleaseName
            Reason = "no customer production deploys (only: $stages)"
        })
    }

    [pscustomobject]@{
        Counted    = @($counted | Sort-Object FirstDeploy)
        NotCounted = @($notCounted)
    }
}

function Group-PlatformReleases {
    # Releases of one platform whose first deploy is within the window of the group's first
    # release count as one release. Groups never span platforms.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Releases,
        [Parameter(Mandatory)][double]$WindowHours
    )
    $window = [timespan]::FromHours($WindowHours)
    foreach ($p in ($Releases | Group-Object Platform)) {
        $current = $null
        foreach ($r in ($p.Group | Sort-Object FirstDeploy, Definition, ReleaseId)) {
            if ($null -eq $current -or ($r.FirstDeploy - $current.Start) -gt $window) {
                if ($null -ne $current) { $current }
                $current = [pscustomobject]@{
                    Platform = $p.Name; Start = $r.FirstDeploy
                    Releases = [System.Collections.Generic.List[object]]::new()
                }
            }
            $current.Releases.Add($r)
        }
        if ($null -ne $current) { $current }
    }
}

function New-ReleaseReport {
    param(
        [Parameter(Mandatory)]$Window,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Groups,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$NotCounted,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Warnings,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$FailedPlatforms
    )
    $platforms = @(foreach ($p in $Config.platforms) {
        # A platform with a failed source is left out of the total and the detail entirely.
        $failed = $FailedPlatforms -contains $p.name
        $pg = @($Groups | Where-Object { -not $failed -and $_.Platform -eq $p.name })
        $tenant = $null
        if ($p.showTenantDeploys -and -not $failed) {
            $tenant = @($Records | Where-Object {
                $_.Platform -eq $p.name -and $_.Time -ge $Window.Start -and $_.Time -lt $Window.End
            }).Count
        }
        [pscustomobject]@{
            Name          = $p.name
            Releases      = $pg.Count
            TenantDeploys = $tenant
            Complete      = -not $failed
            Groups        = $pg
            NotCounted    = @($NotCounted | Where-Object { -not $failed -and $_.Platform -eq $p.name })
        }
    })
    [pscustomobject]@{
        Month     = $Window.Month
        Label     = $Window.Label
        Total     = [int](($platforms | Measure-Object -Property Releases -Sum).Sum)
        Complete  = $FailedPlatforms.Count -eq 0
        Platforms = $platforms
        Warnings  = @($Warnings)
    }
}

function Format-ReleaseReportMarkdown {
    param([Parameter(Mandatory)]$Report, [Parameter(Mandatory)]$TimeZone)
    $sb = [System.Text.StringBuilder]::new()
    $null = $sb.AppendLine("## Releases to production — $($Report.Label)").AppendLine()
    $total = if ($Report.Complete) { "$($Report.Total)" } else { "$($Report.Total) (INCOMPLETE — see warnings)" }
    $null = $sb.AppendLine("**Total releases (Marathon KPI): $total**").AppendLine()
    $null = $sb.AppendLine('| Platform | Releases | Tenant deploys |').AppendLine('|---|---|---|')
    foreach ($p in $Report.Platforms) {
        $rel = if ($p.Complete) { "$($p.Releases)" } else { 'n/a (failed)' }
        $ten = if ($null -eq $p.TenantDeploys) { '–' } else { "$($p.TenantDeploys)" }
        $null = $sb.AppendLine("| $($p.Name) | $rel | $ten |")
    }
    $totalCell = if ($Report.Complete) { "$($Report.Total)" } else { "$($Report.Total) (INCOMPLETE)" }
    $null = $sb.AppendLine("| **Total** | **$totalCell** | |")

    foreach ($p in $Report.Platforms) {
        if ($p.Groups.Count -eq 0) { continue }
        $null = $sb.AppendLine().AppendLine("### $($p.Name)")
        $i = 0
        foreach ($g in $p.Groups) {
            $i++
            $parts = foreach ($r in $g.Releases) {
                $s = "$($r.Label) $($r.ReleaseName)"
                if ($r.Partial) { $s += ' (partial)' }
                if ($null -ne $p.TenantDeploys) { $s += " ($(@($r.Stages) -join ', '))" }
                $s
            }
            $null = $sb.AppendLine("$i. $(Format-LocalDate -Utc $g.Start -TimeZone $TimeZone) — $(@($parts) -join '; ')")
        }
    }

    $nc = @($Report.Platforms | ForEach-Object { $_.NotCounted })
    if ($nc.Count -gt 0) {
        $null = $sb.AppendLine().AppendLine('### Not counted')
        foreach ($n in $nc) { $null = $sb.AppendLine("- $($n.Platform) $($n.Label) $($n.ReleaseName) — $($n.Reason)") }
    }

    $null = $sb.AppendLine().AppendLine('### Warnings')
    if (@($Report.Warnings).Count -eq 0) { $null = $sb.AppendLine('- (none)') }
    foreach ($w in $Report.Warnings) { $null = $sb.AppendLine("- $w") }
    $sb.ToString()
}

function Get-AzdoAuthHeader {
    param([Parameter(Mandatory)][string]$PatEnvVar)
    $pat = [Environment]::GetEnvironmentVariable($PatEnvVar)
    if (-not $pat) { throw "Environment variable '$PatEnvVar' is not set (it must hold a PAT with Release (Read) scope)." }
    @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat")) }
}

function Get-AzdoDeployments {
    param(
        [Parameter(Mandatory)][string]$Org,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][datetime]$MinStarted,
        [Parameter(Mandatory)][datetime]$MaxStarted
    )
    $fmt = "yyyy-MM-dd'T'HH:mm:ss'Z'"
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $min = (ConvertTo-UtcDateTime $MinStarted).ToString($fmt, $inv)
    $max = (ConvertTo-UtcDateTime $MaxStarted).ToString($fmt, $inv)
    $base = "https://vsrm.dev.azure.com/$Org/$([uri]::EscapeDataString($Project))/_apis/release/deployments"
    $all = [System.Collections.Generic.List[object]]::new()
    $token = $null
    do {
        $uri = "${base}?minStartedTime=$min&maxStartedTime=$max&`$top=100&api-version=7.1"
        if ($token) { $uri += "&continuationToken=$([uri]::EscapeDataString($token))" }
        $resp = Invoke-WebRequest -Uri $uri -Headers $Headers -UseBasicParsing
        # Decode the raw bytes as UTF-8 ourselves so stage names like 'Tranås' survive
        # even if the response lacks a charset.
        $body = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json
        foreach ($d in @($body.value)) { $all.Add($d) }
        $token = $null
        if ($resp.Headers.ContainsKey('x-ms-continuationtoken')) { $token = @($resp.Headers['x-ms-continuationtoken'])[0] }
    } while ($token)
    $all.ToArray()
}

function Invoke-Main {
    param(
        [string]$Month,
        [string]$Json,
        [string]$Config,
        [datetime]$Now = [datetime]::UtcNow
    )
    # Stage names contain å/ä/ö/ø; some hosts (no console attached) refuse this, which is harmless.
    try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
    if (-not $Config) { $Config = Join-Path $PSScriptRoot 'marathon-releases.config.json' }
    $cfg = Read-ReleaseConfig -Path $Config
    $window = Get-MonthWindow -Month $Month -TimeZone $cfg.timeZone -Now $Now
    $min = $window.Start.AddDays(-[double]$cfg.lookbackDays)
    $max = $window.End.AddHours([double]$cfg.supersedeWindowHours)

    $records = [System.Collections.Generic.List[object]]::new()
    $excluded = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $failed = [System.Collections.Generic.List[string]]::new()

    foreach ($p in $cfg.platforms) {
        foreach ($s in $p.sources) {
            try {
                $headers = Get-AzdoAuthHeader -PatEnvVar $s.patEnvVar
                $deps = @(Get-AzdoDeployments -Org $s.org -Project $s.project -Headers $headers -MinStarted $min -MaxStarted $max)
            } catch {
                $warnings.Add("FAILED to read $($s.org)/$($s.project) for $($p.name): $($_.Exception.Message) $($p.name) is left out of the total.")
                if ($failed -notcontains $p.name) { $failed.Add($p.name) }
                continue
            }
            if ($deps.Count -eq 0) {
                $warnings.Add("No deployments at all in $($s.org)/$($s.project) between $($min.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)) and $($max.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)) (UTC dates, yyyy-MM-dd); check that its release pipelines have not moved.")
            }
            $sel = Select-ProductionDeploys -Deployments $deps -Source $s -Platform $p.name `
                -CountedStatuses @($cfg.countedStatuses) -WindowStart $window.Start -WindowEnd $window.End
            foreach ($r in $sel.Records) { $records.Add($r) }
            foreach ($r in $sel.Excluded) { $excluded.Add($r) }
            foreach ($w in $sel.Warnings) { $warnings.Add($w) }
        }
    }

    # A platform with a failed source is dropped entirely so a partial count is never reported as real.
    $okRecords = @($records | Where-Object { $failed -notcontains $_.Platform })
    $okExcluded = @($excluded | Where-Object { $failed -notcontains $_.Platform })

    $superseded = Find-SupersededReleases -Records $okRecords -WindowHours ([double]$cfg.supersedeWindowHours)
    $res = Get-CountedReleases -Records $okRecords -Excluded $okExcluded -Superseded $superseded `
        -WindowStart $window.Start -WindowEnd $window.End -TimeZone $window.TimeZone
    $groups = @(Group-PlatformReleases -Releases $res.Counted -WindowHours ([double]$cfg.groupWindowHours))

    if ((ConvertTo-UtcDateTime $Now) -lt $max) {
        $finalAt = [TimeZoneInfo]::ConvertTimeFromUtc($max, $window.TimeZone).ToString('yyyy-MM-dd HH:mm')
        $warnings.Insert(0, "Not final yet: releases replaced within $($cfg.supersedeWindowHours) h of month end can still change the count. Run again after $finalAt ($($cfg.timeZone) time).")
    }

    $report = New-ReleaseReport -Window $window -Config $cfg -Records $okRecords -Groups $groups `
        -NotCounted $res.NotCounted -Warnings @($warnings) -FailedPlatforms @($failed)
    if ($Json) { $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Json -Encoding utf8 }
    Format-ReleaseReportMarkdown -Report $report -TimeZone $window.TimeZone
}

# Guard: when dot-sourced for tests, InvocationName is '.', so Main does not run.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main @PSBoundParameters
}
