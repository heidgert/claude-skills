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
    Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
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
        return 'preprod'
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
