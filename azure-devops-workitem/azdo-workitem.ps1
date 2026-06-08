[CmdletBinding()]
param(
    [string]$Action,
    [int]$Id,
    [string]$Type,
    [string]$Title,
    [string]$Body,
    [hashtable]$Fields = @{},
    [string]$AssignedTo,
    [string]$Org,
    [string]$Project,
    [string]$PatEnvVar,
    [string]$ConfigPath,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- functions are added in later tasks ---

function Find-AzdoConfigFile {
    param([string]$StartDir)
    $dir = Get-Item -LiteralPath $StartDir
    while ($null -ne $dir) {
        $candidate = Join-Path $dir.FullName '.azuredevops.json'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
        $dir = $dir.Parent
    }
    return $null
}

function Resolve-AzdoConfig {
    param(
        [string]$ConfigPath,
        [string]$StartDir = (Get-Location).Path
    )
    if (-not $ConfigPath) {
        $ConfigPath = Find-AzdoConfigFile -StartDir $StartDir
    }
    if (-not $ConfigPath -or -not (Test-Path -LiteralPath $ConfigPath)) {
        throw "No .azuredevops.json found (searched from '$StartDir' upward). Create one (see .azuredevops.sample.json) or pass -ConfigPath / explicit -Org and -Project."
    }
    return Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
}

function Invoke-Main {
    param(
        [string]$Action, [int]$Id, [string]$Type, [string]$Title, [string]$Body,
        [hashtable]$Fields, [string]$AssignedTo, [string]$Org, [string]$Project,
        [string]$PatEnvVar, [string]$ConfigPath, [switch]$DryRun
    )
    throw "not implemented yet"
}

# Guard: when dot-sourced for tests, InvocationName is '.', so Main does not run.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main -Action $Action -Id $Id -Type $Type -Title $Title -Body $Body `
        -Fields $Fields -AssignedTo $AssignedTo -Org $Org -Project $Project `
        -PatEnvVar $PatEnvVar -ConfigPath $ConfigPath -DryRun:$DryRun
}
