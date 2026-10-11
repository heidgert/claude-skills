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
