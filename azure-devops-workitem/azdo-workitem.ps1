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

function Resolve-AzdoBodyField {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string]$Type
    )
    $map = $Config.bodyFieldByType
    if ($null -ne $map -and ($map.PSObject.Properties.Name -contains $Type)) {
        return $map.$Type
    }
    return 'System.Description'
}

function Build-AzdoPatch {
    [CmdletBinding()]  # required so -WarningVariable (a common parameter) is honored
    param(
        [string]$Title,
        [string]$Body,
        [string]$BodyField,
        [string]$AssignedTo,
        [hashtable]$Fields = @{}
    )
    $ops = [System.Collections.Generic.List[object]]::new()
    $written = [System.Collections.Generic.HashSet[string]]::new()

    function Add-Op([string]$field, $value) {
        $ops.Add([pscustomobject]@{ op = 'add'; path = "/fields/$field"; value = $value }) | Out-Null
        [void]$written.Add($field)
    }

    if ($Title)      { Add-Op 'System.Title' $Title }
    if ($Body)       {
        if (-not $BodyField) { throw "Build-AzdoPatch: -Body given without -BodyField." }
        Add-Op $BodyField $Body
    }
    if ($AssignedTo) { Add-Op 'System.AssignedTo' $AssignedTo }

    foreach ($key in $Fields.Keys) {
        if ($written.Contains($key)) {
            Write-Warning "Field '$key' is set by both -Body/-Title/-AssignedTo and -Fields; the explicit value wins and the -Fields entry is ignored."
            continue
        }
        Add-Op $key $Fields[$key]
    }
    return $ops.ToArray()
}

function New-AzdoRequestPlan {
    param(
        [Parameter(Mandatory)][ValidateSet('create','update')][string]$Action,
        [Parameter(Mandatory)][string]$Org,
        [Parameter(Mandatory)][string]$Project,
        [string]$Type,
        [int]$Id,
        [Parameter(Mandatory)][object[]]$Patch
    )
    $orgTrimmed = $Org.TrimEnd('/')
    $projEnc = [uri]::EscapeDataString($Project)
    if ($Action -eq 'create') {
        if (-not $Type) { throw "New-AzdoRequestPlan: -Type is required for create." }
        # Work-item create path is /_apis/wit/workitems/${Type}; the literal '$' must be encoded as %24.
        $typeEnc = '%24' + [uri]::EscapeDataString($Type)
        $url = "$orgTrimmed/$projEnc/_apis/wit/workitems/$typeEnc`?api-version=7.1"
        $method = 'POST'
    }
    else {
        if (-not $Id) { throw "New-AzdoRequestPlan: -Id is required for update." }
        $url = "$orgTrimmed/$projEnc/_apis/wit/workitems/$Id`?api-version=7.1"
        $method = 'PATCH'
    }

    # Pipe (don't use -InputObject): piping enumerates the ops so a multi-op patch
    # serializes as [{...},{...}]. -InputObject $array -AsArray would double-wrap to [[...]].
    # -AsArray keeps the single-op case as [{...}] rather than a bare object.
    $json = $Patch | ConvertTo-Json -Depth 10 -AsArray
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

    return [pscustomobject]@{
        Method        = $method
        Url           = $url
        ContentType   = 'application/json-patch+json; charset=utf-8'
        Patch         = $Patch
        Json          = $json
        BodyBytes     = $bytes
        BodyByteCount = $bytes.Length
    }
}

function Get-AzdoAuthHeader {
    param([Parameter(Mandatory)][string]$PatEnvVar)
    $pat = [Environment]::GetEnvironmentVariable($PatEnvVar)
    if ([string]::IsNullOrWhiteSpace($pat)) {
        throw "PAT environment variable '$PatEnvVar' is not set or is empty. Set it (e.g. `$env:$PatEnvVar = '<your PAT>') and retry."
    }
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$pat"))
    return @{ Authorization = "Basic $b64" }
}

function Get-AzdoWorkItemType { param($Org,$Project,$Id,$PatEnvVar) throw "not implemented yet (Task 7)" }
function Invoke-AzdoAndVerify { param($Plan,$PatEnvVar,$Org,$Project,$BodyField) throw "not implemented yet (Task 7)" }

function Invoke-Main {
    param(
        [string]$Action, [int]$Id, [string]$Type, [string]$Title, [string]$Body,
        [hashtable]$Fields = @{}, [string]$AssignedTo, [string]$Org, [string]$Project,
        [string]$PatEnvVar, [string]$ConfigPath, [switch]$DryRun
    )
    if ($Action -notin @('create','update')) {
        throw "-Action must be 'create' or 'update' (got '$Action')."
    }

    $cfg = Resolve-AzdoConfig -ConfigPath $ConfigPath

    if (-not $Org)        { $Org = $cfg.org }
    if (-not $Project)    { $Project = $cfg.project }
    if (-not $PatEnvVar)  { $PatEnvVar = $cfg.patEnvVar }
    if (-not $AssignedTo) { $AssignedTo = $cfg.defaultAssignee }
    if (-not $Org)     { throw "Org not provided and not in config." }
    if (-not $Project) { throw "Project not provided and not in config." }

    if ($Action -eq 'create') {
        if (-not $Title) { throw "-Title is required for create." }
        if (-not $Type)  { $Type = $cfg.defaultType }
        if (-not $Type)  { throw "-Type not provided and no defaultType in config." }
    }

    # Body field needs a type. On update without -Type, fetch the item to learn its type.
    $bodyField = $null
    if ($Body) {
        $effectiveType = $Type
        if (-not $effectiveType -and $Action -eq 'update') {
            $effectiveType = Get-AzdoWorkItemType -Org $Org -Project $Project -Id $Id -PatEnvVar $PatEnvVar
        }
        if (-not $effectiveType) { throw "Cannot resolve body field without a work-item type." }
        $bodyField = Resolve-AzdoBodyField -Config $cfg -Type $effectiveType
    }

    $patch = Build-AzdoPatch -Title $Title -Body $Body -BodyField $bodyField -AssignedTo $AssignedTo -Fields $Fields
    if ($patch.Count -eq 0) { throw "Nothing to do: no Title, Body, AssignedTo, or Fields supplied." }

    $plan = New-AzdoRequestPlan -Action $Action -Org $Org -Project $Project -Type $Type -Id $Id -Patch $patch
    $plan | Add-Member -NotePropertyName BodyField -NotePropertyValue $bodyField -PassThru | Out-Null

    if ($DryRun) {
        Write-Host "DRY RUN — no request sent." -ForegroundColor Yellow
        Write-Host "$($plan.Method) $($plan.Url)"
        Write-Host "Content-Type: $($plan.ContentType)"
        Write-Host "Authorization: Basic <redacted>"
        Write-Host "Body ($($plan.BodyByteCount) bytes):"
        Write-Host $plan.Json
        return $plan
    }

    return Invoke-AzdoAndVerify -Plan $plan -PatEnvVar $PatEnvVar -Org $Org -Project $Project -BodyField $bodyField
}

# Guard: when dot-sourced for tests, InvocationName is '.', so Main does not run.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-Main @PSBoundParameters
}
