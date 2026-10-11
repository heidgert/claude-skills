BeforeAll {
    # Dot-source the script to load its functions without executing Main.
    . "$PSScriptRoot/marathon-releases.ps1"
    $ConfigPath = Join-Path $PSScriptRoot 'marathon-releases.config.json'

    function Get-Utc { param([string]$s) ConvertTo-UtcDateTime $s }

    # A raw deployment as returned by the vsrm deployments API (only the fields the script reads).
    function New-Dep {
        param([string]$Def, [int]$Rel, [string]$Stage, [string]$Time,
              [string]$Status = 'succeeded', [string]$RelName = "Release-$Rel")
        [pscustomobject]@{
            releaseDefinition  = [pscustomobject]@{ name = $Def }
            release            = [pscustomobject]@{ id = $Rel; name = $RelName }
            releaseEnvironment = [pscustomobject]@{ name = $Stage }
            deploymentStatus   = $Status
            completedOn        = $Time
        }
    }

    # A production record as produced by Select-ProductionDeploys.
    function New-Rec {
        param([string]$Def, [int]$Rel, [string]$Stage, [string]$Time,
              [string]$Platform = 'Mobilise', [string]$Label = $Def,
              [string]$Status = 'succeeded', [string]$RelName = "Release-$Rel")
        [pscustomobject]@{
            Platform = $Platform; Definition = $Def; Label = $Label
            ReleaseId = $Rel; ReleaseName = $RelName; Stage = $Stage
            Time = (ConvertTo-UtcDateTime $Time); Status = $Status
        }
    }
}

Describe 'ConvertTo-UtcDateTime' {
    It 'parses ISO strings with Z as UTC' {
        (ConvertTo-UtcDateTime '2026-09-03T10:34:10.873Z').ToString('o') | Should -Be '2026-09-03T10:34:10.8730000Z'
    }
    It 'keeps DateTime values that are already UTC' {
        $d = [datetime]::new(2026, 9, 3, 10, 0, 0, [DateTimeKind]::Utc)
        ConvertTo-UtcDateTime $d | Should -Be $d
        (ConvertTo-UtcDateTime $d).Kind | Should -Be 'Utc'
    }
    It 'returns $null for empty input' {
        ConvertTo-UtcDateTime $null | Should -BeNullOrEmpty
        ConvertTo-UtcDateTime '' | Should -BeNullOrEmpty
    }
}

Describe 'Get-MonthWindow' {
    It 'maps September 2026 to Stockholm midnight boundaries (CEST, UTC+2)' {
        $w = Get-MonthWindow -Month '2026-09' -TimeZone 'Europe/Stockholm'
        $w.Start | Should -Be (Get-Utc '2026-08-31T22:00:00Z')
        $w.End   | Should -Be (Get-Utc '2026-09-30T22:00:00Z')
        $w.Month | Should -Be '2026-09'
        $w.Label | Should -Be 'September 2026'
    }
    It 'handles the DST change at the end of October' {
        $w = Get-MonthWindow -Month '2026-10' -TimeZone 'Europe/Stockholm'
        $w.Start | Should -Be (Get-Utc '2026-09-30T22:00:00Z')
        $w.End   | Should -Be (Get-Utc '2026-10-31T23:00:00Z')
    }
    It 'defaults to the previous month, across a year boundary' {
        $w = Get-MonthWindow -TimeZone 'Europe/Stockholm' -Now (Get-Utc '2027-01-10T08:00:00Z')
        $w.Month | Should -Be '2026-12'
    }
    It 'uses Stockholm time to decide the current month for the default' {
        # 2026-09-30T22:30Z is 00:30 on 1 October in Stockholm, so the previous month is September.
        $w = Get-MonthWindow -TimeZone 'Europe/Stockholm' -Now (Get-Utc '2026-09-30T22:30:00Z')
        $w.Month | Should -Be '2026-09'
    }
    It 'rejects a malformed month' {
        { Get-MonthWindow -Month '2026-9' -TimeZone 'Europe/Stockholm' } | Should -Throw '*yyyy-MM*'
    }
}

Describe 'marathon-releases.config.json' {
    BeforeAll { $cfg = Read-ReleaseConfig -Path $ConfigPath }

    It 'lists the three platforms in report order' {
        ($cfg.platforms.name -join ',') | Should -Be 'Troman,Kaskelot,Mobilise'
    }
    It 'gives every definition exactly one stage mode and no stage in both lists' {
        foreach ($s in $cfg.platforms.sources) {
            foreach ($d in $s.definitions) {
                $names = $d.PSObject.Properties.Name
                (($names -contains 'includeStages') -xor ($names -contains 'excludeStages')) | Should -BeTrue -Because $d.name
                if ($names -contains 'excludeStages') {
                    @($d.excludeStages | Where-Object { @($d.knownCustomerStages) -contains $_ }) | Should -BeNullOrEmpty -Because $d.name
                }
            }
        }
    }
    It 'keeps Swedish and Norwegian characters intact' {
        $classic = $cfg.platforms.sources.definitions | Where-Object name -eq 'Mobilise'
        $classic.knownCustomerStages | Should -Contain 'Tranås'
        $classic.knownCustomerStages | Should -Contain 'Bjørnafjorden'
    }
    It 'throws a clear error when the config is missing' {
        { Read-ReleaseConfig -Path 'C:\nope\missing.json' } | Should -Throw '*Config not found*'
    }
}

Describe 'Get-StageClass' {
    BeforeAll {
        $inc = [pscustomobject]@{ name = 'Troman/Valman Webb'; includeStages = @('Prod') }
        $exc = [pscustomobject]@{ name = 'Mobilise'; excludeStages = @('val', 'UppsalaDev'); knownCustomerStages = @('Tranås', 'Uppsalakommun') }
    }
    It 'include mode: the listed stage is production, others are pre-prod' {
        Get-StageClass -Definition $inc -Stage 'Prod' | Should -Be 'production'
        Get-StageClass -Definition $inc -Stage 'Kundtest' | Should -Be 'preprod'
    }
    It 'exclude mode: excluded, known customer and new stages' {
        Get-StageClass -Definition $exc -Stage 'UppsalaDev' | Should -Be 'excluded'
        Get-StageClass -Definition $exc -Stage 'Uppsalakommun' | Should -Be 'production'
        Get-StageClass -Definition $exc -Stage 'Nyköping' | Should -Be 'new'
    }
    It 'matches regardless of case and Unicode normalization (decomposed å)' {
        $nfd = 'Tran' + 'a' + [char]0x030A + 's'
        Get-StageClass -Definition $exc -Stage $nfd | Should -Be 'production'
        Get-StageClass -Definition $exc -Stage 'uppsaladev' | Should -Be 'excluded'
    }
}

Describe 'Select-ProductionDeploys' {
    BeforeAll {
        $src = [pscustomobject]@{
            org = 'mobilise'; project = 'Mobilise'; patEnvVar = 'X'
            ignoreDefinitions = @('Fredrik testar')
            definitions = @(
                [pscustomobject]@{ name = 'Mobilise'; label = 'Classic'; excludeStages = @('val', 'UppsalaDev'); knownCustomerStages = @('Uppsalakommun', 'Ringerike', 'Cup') }
            )
        }
        $sel = @{
            Source = $src; Platform = 'Mobilise'
            CountedStatuses = @('succeeded', 'partiallySucceeded')
            WindowStart = (Get-Utc '2026-08-31T22:00:00Z'); WindowEnd = (Get-Utc '2026-09-30T22:00:00Z')
        }
    }
    It 'keeps customer-stage deploys as records with platform, label and UTC time' {
        $r = Select-ProductionDeploys -Deployments @(New-Dep 'Mobilise' 490 'Uppsalakommun' '2026-09-03T10:34:10Z') @sel
        $r.Records.Count | Should -Be 1
        $r.Records[0].Platform | Should -Be 'Mobilise'
        $r.Records[0].Label | Should -Be 'Classic'
        $r.Records[0].ReleaseId | Should -Be 490
        $r.Records[0].Time | Should -Be (Get-Utc '2026-09-03T10:34:10Z')
    }
    It 'puts excluded-stage deploys in Excluded, not Records' {
        $r = Select-ProductionDeploys -Deployments @(New-Dep 'Mobilise' 492 'UppsalaDev' '2026-09-08T10:00:00Z') @sel
        $r.Records.Count | Should -Be 0
        $r.Excluded.Count | Should -Be 1
        $r.Excluded[0].Stage | Should -Be 'UppsalaDev'
    }
    It 'collapses a failed attempt, a successful retry and a redeploy into one record (earliest success)' {
        $deps = @(
            New-Dep 'Mobilise' 496 'Ringerike' '2026-09-21T09:00:00Z' -Status 'failed'
            New-Dep 'Mobilise' 496 'Ringerike' '2026-09-21T09:30:00Z'
            New-Dep 'Mobilise' 496 'Ringerike' '2026-09-22T09:30:00Z'
        )
        $r = Select-ProductionDeploys -Deployments $deps @sel
        $r.Records.Count | Should -Be 1
        $r.Records[0].Time | Should -Be (Get-Utc '2026-09-21T09:30:00Z')
    }
    It 'counts partiallySucceeded and skips failed, canceled, in-progress and unfinished deploys' {
        $deps = @(
            New-Dep 'Mobilise' 495 'Cup' '2026-09-15T10:00:00Z' -Status 'partiallySucceeded'
            New-Dep 'Mobilise' 496 'Cup' '2026-09-16T10:00:00Z' -Status 'failed'
            New-Dep 'Mobilise' 497 'Cup' '2026-09-17T10:00:00Z' -Status 'canceled'
            New-Dep 'Mobilise' 498 'Cup' $null -Status 'inProgress'
            New-Dep 'Mobilise' 499 'Cup' $null
        )
        $r = Select-ProductionDeploys -Deployments $deps @sel
        $r.Records.Count | Should -Be 1
        $r.Records[0].ReleaseId | Should -Be 495
        $r.Records[0].Status | Should -Be 'partiallySucceeded'
    }
    It 'warns once about a new stage and still counts it' {
        $deps = @(
            New-Dep 'Mobilise' 498 'Nyköping' '2026-09-22T10:00:00Z'
            New-Dep 'Mobilise' 499 'Nyköping' '2026-09-23T10:00:00Z'
        )
        $r = Select-ProductionDeploys -Deployments $deps @sel
        $r.Records.Count | Should -Be 2
        $r.Warnings.Count | Should -Be 1
        $r.Warnings[0] | Should -BeLike "*New stage 'Nyköping'*"
    }
    It 'does not warn about a new stage seen only outside the month' {
        $r = Select-ProductionDeploys -Deployments @(New-Dep 'Mobilise' 480 'Nyköping' '2026-08-10T10:00:00Z') @sel
        $r.Warnings.Count | Should -Be 0
    }
    It 'warns about unknown definitions and silently skips ignored ones' {
        $deps = @(
            New-Dep 'Mobilise-Beta' 1 'Cup' '2026-09-10T10:00:00Z'
            New-Dep 'Fredrik testar' 7 'val' '2026-09-10T10:00:00Z'
        )
        $r = Select-ProductionDeploys -Deployments $deps @sel
        $r.Records.Count | Should -Be 0
        $r.Warnings.Count | Should -Be 1
        $r.Warnings[0] | Should -BeLike "*Unknown release definition 'Mobilise-Beta'*"
    }
    It 'drops pre-prod stages of include-mode definitions without warnings' {
        $tsrc = [pscustomobject]@{
            org = 'troman-ab'; project = 'Troman'; ignoreDefinitions = @()
            definitions = @([pscustomobject]@{ name = 'troman-publik'; label = 'publik'; includeStages = @('Prod') })
        }
        $deps = @(
            New-Dep 'troman-publik' 5 'Staging' '2026-09-10T10:00:00Z'
            New-Dep 'troman-publik' 5 'Prod' '2026-09-11T10:00:00Z'
        )
        $r = Select-ProductionDeploys -Deployments $deps -Source $tsrc -Platform 'Troman' -CountedStatuses @('succeeded') `
            -WindowStart (Get-Utc '2026-08-31T22:00:00Z') -WindowEnd (Get-Utc '2026-09-30T22:00:00Z')
        $r.Records.Count | Should -Be 1
        $r.Records[0].Stage | Should -Be 'Prod'
        $r.Excluded.Count | Should -Be 0
        $r.Warnings.Count | Should -Be 0
    }
    It 'accepts an empty deployment list' {
        $r = Select-ProductionDeploys -Deployments @() @sel
        $r.Records.Count | Should -Be 0
        $r.Warnings.Count | Should -Be 0
    }
}


Describe 'Find-SupersededReleases' {
    It 'does not fold 490 into 491 when they are 33 hours apart on Uppsalakommun' {
        $recs = @(
            New-Rec 'Mobilise' 490 'Uppsalakommun' '2026-09-03T10:34:10Z'
            New-Rec 'Mobilise' 491 'Uppsalakommun' '2026-09-04T19:45:09Z'
        )
        (Find-SupersededReleases -Records $recs -WindowHours 24).Count | Should -Be 0
    }
    It 'folds a release replaced on every stage within 24 hours' {
        $recs = @(
            New-Rec 'Mobilise' 492 'Cup' '2026-09-08T10:00:00Z'
            New-Rec 'Mobilise' 492 'Habo' '2026-09-08T11:00:00Z'
            New-Rec 'Mobilise' 493 'Cup' '2026-09-08T15:00:00Z'
            New-Rec 'Mobilise' 493 'Habo' '2026-09-09T09:00:00Z'
        )
        $s = Find-SupersededReleases -Records $recs -WindowHours 24
        (@($s.Keys) -join ',') | Should -Be 'Mobilise|492'
        $s['Mobilise|492'].ReleaseName | Should -Be 'Release-493'
    }
    It 'does not fold a release replaced on only some of its stages' {
        $recs = @(
            New-Rec 'Mobilise' 492 'Cup' '2026-09-08T10:00:00Z'
            New-Rec 'Mobilise' 492 'Habo' '2026-09-08T11:00:00Z'
            New-Rec 'Mobilise' 493 'Cup' '2026-09-08T15:00:00Z'
        )
        (Find-SupersededReleases -Records $recs -WindowHours 24).Count | Should -Be 0
    }
    It 'treats exactly 24 hours as within the window' {
        $recs = @(
            New-Rec 'Mobilise' 492 'Cup' '2026-09-08T10:00:00Z'
            New-Rec 'Mobilise' 493 'Cup' '2026-09-09T10:00:00Z'
        )
        (Find-SupersededReleases -Records $recs -WindowHours 24).ContainsKey('Mobilise|492') | Should -BeTrue
    }
    It 'only compares releases of the same definition' {
        $recs = @(
            New-Rec 'Mobilise' 496 'Ringerike' '2026-09-21T09:30:00Z'
            New-Rec 'core web-Api Release' 534 'Ringerike' '2026-09-21T09:40:00Z'
        )
        (Find-SupersededReleases -Records $recs -WindowHours 24).Count | Should -Be 0
    }
    It 'ignores an older release deployed after a newer one' {
        $recs = @(
            New-Rec 'Mobilise' 493 'Cup' '2026-09-08T10:00:00Z'
            New-Rec 'Mobilise' 492 'Cup' '2026-09-08T12:00:00Z'
        )
        (Find-SupersededReleases -Records $recs -WindowHours 24).Count | Should -Be 0
    }
}

Describe 'Get-CountedReleases' {
    BeforeAll {
        $w = @{
            WindowStart = (Get-Utc '2026-08-31T22:00:00Z')
            WindowEnd   = (Get-Utc '2026-09-30T22:00:00Z')
            TimeZone    = [TimeZoneInfo]::FindSystemTimeZoneById('Europe/Stockholm')
        }
    }
    It 'counts a release in the month of its first production deploy, in Stockholm time' {
        # 2026-08-31T22:30Z is 00:30 on 1 September in Stockholm.
        $r = Get-CountedReleases -Records @(New-Rec 'Mobilise' 489 'Cup' '2026-08-31T22:30:00Z') @w
        $r.Counted.Count | Should -Be 1
        $r.Counted[0].FirstDeploy | Should -Be (Get-Utc '2026-08-31T22:30:00Z')
    }
    It 'does not count a release first deployed in an earlier month, and says why' {
        $recs = @(
            New-Rec 'Mobilise' 488 'Cup' '2026-08-28T10:00:00Z'
            New-Rec 'Mobilise' 488 'Habo' '2026-09-02T10:00:00Z'
        )
        $r = Get-CountedReleases -Records $recs @w
        $r.Counted.Count | Should -Be 0
        $r.NotCounted[0].Reason | Should -BeLike '*2026-08-28*earlier month*'
    }
    It 'ignores releases first deployed after the month (look-ahead data)' {
        $r = Get-CountedReleases -Records @(New-Rec 'Mobilise' 500 'Cup' '2026-10-01T05:00:00Z') @w
        $r.Counted.Count | Should -Be 0
        $r.NotCounted.Count | Should -Be 0
    }
    It 'leaves out superseded releases and names the release they were folded into' {
        $recs = @(
            New-Rec 'Mobilise' 492 'Cup' '2026-09-08T10:00:00Z'
            New-Rec 'Mobilise' 493 'Cup' '2026-09-08T15:00:00Z'
        )
        $sup = Find-SupersededReleases -Records $recs -WindowHours 24
        $r = Get-CountedReleases -Records $recs -Superseded $sup @w
        (@($r.Counted.ReleaseName) -join ',') | Should -Be 'Release-493'
        $r.NotCounted[0].Reason | Should -BeLike '*folded into Mobilise Release-493*'
    }
    It 'flags partial success and lists the stages in deploy order' {
        $recs = @(
            New-Rec 'Mobilise' 491 'Motala' '2026-09-04T20:00:00Z' -Status 'partiallySucceeded'
            New-Rec 'Mobilise' 491 'Uppsalakommun' '2026-09-04T19:45:09Z'
        )
        $r = Get-CountedReleases -Records $recs @w
        $r.Counted[0].Partial | Should -BeTrue
        ($r.Counted[0].Stages -join ',') | Should -Be 'Uppsalakommun,Motala'
    }
    It 'reports releases that only reached excluded stages' {
        $exc = @(New-Rec 'Mobilise' 492 'UppsalaDev' '2026-09-08T10:00:00Z' -Label 'Classic')
        $r = Get-CountedReleases -Records @() -Excluded $exc @w
        $r.NotCounted.Count | Should -Be 1
        $r.NotCounted[0].Label | Should -Be 'Classic'
        $r.NotCounted[0].Reason | Should -Be 'no customer production deploys (only: UppsalaDev)'
    }
    It 'does not report an excluded deploy when the release also reached a customer' {
        $recs = @(New-Rec 'Mobilise' 490 'Uppsalakommun' '2026-09-03T10:34:10Z')
        $exc = @(New-Rec 'Mobilise' 490 'UppsalaDev' '2026-09-03T09:00:00Z')
        $r = Get-CountedReleases -Records $recs -Excluded $exc @w
        $r.NotCounted.Count | Should -Be 0
    }
}

Describe 'Group-PlatformReleases' {
    BeforeAll {
        function New-Release {
            param([string]$Platform, [string]$Def, [int]$Rel, [string]$First)
            [pscustomobject]@{
                Platform = $Platform; Definition = $Def; Label = $Def; ReleaseId = $Rel
                ReleaseName = "Release-$Rel"; FirstDeploy = (Get-Utc $First); Stages = @('x'); Partial = $false
            }
        }
    }
    It 'merges Troman components released together into one' {
        $rel = @(
            New-Release 'Troman' 'troman-politiker-back' 8 '2026-09-30T17:05:00Z'
            New-Release 'Troman' 'troman-politiker-front' 12 '2026-09-30T17:08:00Z'
            New-Release 'Troman' 'Troman/Valman Webb' 22 '2026-09-30T17:11:42Z'
        )
        $g = @(Group-PlatformReleases -Releases $rel -WindowHours 24)
        $g.Count | Should -Be 1
        $g[0].Releases.Count | Should -Be 3
        $g[0].Start | Should -Be (Get-Utc '2026-09-30T17:05:00Z')
    }
    It 'keeps Kaskelot 4 Sep and 16 Sep as two releases' {
        $rel = @(
            New-Release 'Kaskelot' 'Internal application' 101 '2026-09-04T13:00:00Z'
            New-Release 'Kaskelot' 'External application' 201 '2026-09-04T13:10:00Z'
            New-Release 'Kaskelot' 'Internal application' 105 '2026-09-16T14:00:00Z'
        )
        $g = @(Group-PlatformReleases -Releases $rel -WindowHours 24)
        $g.Count | Should -Be 2
        $g[0].Releases.Count | Should -Be 2
    }
    It 'anchors the window at the start of the group, not at the previous release' {
        $rel = @(
            New-Release 'Mobilise' 'Mobilise' 1 '2026-09-01T00:00:00Z'
            New-Release 'Mobilise' 'Mobilise' 2 '2026-09-01T20:00:00Z'
            New-Release 'Mobilise' 'Mobilise' 3 '2026-09-02T06:00:00Z'
        )
        $g = @(Group-PlatformReleases -Releases $rel -WindowHours 24)
        $g.Count | Should -Be 2
        $g[0].Releases.Count | Should -Be 2
        $g[1].Releases.Count | Should -Be 1
    }
    It 'never groups across platforms' {
        $rel = @(
            New-Release 'Troman' 'troman-publik' 1 '2026-09-10T10:00:00Z'
            New-Release 'Kaskelot' 'Internal application' 2 '2026-09-10T10:05:00Z'
        )
        @(Group-PlatformReleases -Releases $rel -WindowHours 24).Count | Should -Be 2
    }
    It 'returns nothing for no releases' {
        @(Group-PlatformReleases -Releases @() -WindowHours 24).Count | Should -Be 0
    }
}
