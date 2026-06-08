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
