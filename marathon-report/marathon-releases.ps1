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
