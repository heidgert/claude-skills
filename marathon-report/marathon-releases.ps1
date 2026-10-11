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
