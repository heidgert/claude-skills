BeforeAll {
    # Dot-source the script to load its functions without executing Main.
    . "$PSScriptRoot/azdo-workitem.ps1"
}

Describe 'azdo-workitem' {
    It 'loads without executing Main' {
        Get-Command Invoke-Main -ErrorAction Stop | Should -Not -BeNullOrEmpty
    }

    Context 'Resolve-AzdoConfig' {
        BeforeAll {
            $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("azdocfg_" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $script:tmp | Out-Null
            $sub = Join-Path $script:tmp 'a/b/c'
            New-Item -ItemType Directory -Force -Path $sub | Out-Null
            @{
                org = 'https://dev.azure.com/contoso'; project = 'Proj'
                patEnvVar = 'MY_PAT'; defaultType = 'Bug'
                bodyFieldByType = @{ Bug = 'Microsoft.VSTS.TCM.ReproSteps'; 'Product Backlog Item' = 'System.Description' }
                defaultAssignee = 'a@b.com'
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:tmp '.azuredevops.json') -Encoding utf8
            $script:sub = $sub
        }
        AfterAll { Remove-Item -Recurse -Force -LiteralPath $script:tmp }

        It 'finds config by walking up from a subdirectory' {
            $cfg = Resolve-AzdoConfig -StartDir $script:sub
            $cfg.org | Should -Be 'https://dev.azure.com/contoso'
            $cfg.bodyFieldByType.Bug | Should -Be 'Microsoft.VSTS.TCM.ReproSteps'
        }
        It 'throws a clear error when no config is found' {
            $orphan = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $orphan | Out-Null
            # Guard: this test assumes no ancestor of the orphan dir has a real config.
            # Fail loudly (not silently) if the host tree violates that assumption.
            $anc = Get-Item -LiteralPath $orphan
            $ancestorHasConfig = $false
            while ($null -ne $anc) {
                if (Test-Path -LiteralPath (Join-Path $anc.FullName '.azuredevops.json')) { $ancestorHasConfig = $true; break }
                $anc = $anc.Parent
            }
            $ancestorHasConfig | Should -BeFalse -Because 'an ancestor .azuredevops.json would defeat the not-found test; relocate the orphan dir'
            { Resolve-AzdoConfig -StartDir $orphan } | Should -Throw '*.azuredevops.json*'
            Remove-Item -Recurse -Force -LiteralPath $orphan
        }
        It 'finds config in the StartDir itself (not only ancestors)' {
            $cfg = Resolve-AzdoConfig -StartDir $script:tmp
            $cfg.project | Should -Be 'Proj'
        }
        It 'uses an explicit ConfigPath when given' {
            $cfg = Resolve-AzdoConfig -ConfigPath (Join-Path $script:tmp '.azuredevops.json')
            $cfg.project | Should -Be 'Proj'
        }
    }

    Context 'Resolve-AzdoBodyField' {
        BeforeAll {
            $script:cfg = [pscustomobject]@{
                bodyFieldByType = [pscustomobject]@{
                    'Bug' = 'Microsoft.VSTS.TCM.ReproSteps'
                    'Product Backlog Item' = 'System.Description'
                }
            }
        }
        It 'maps Bug to ReproSteps' {
            Resolve-AzdoBodyField -Config $script:cfg -Type 'Bug' | Should -Be 'Microsoft.VSTS.TCM.ReproSteps'
        }
        It 'maps PBI to System.Description' {
            Resolve-AzdoBodyField -Config $script:cfg -Type 'Product Backlog Item' | Should -Be 'System.Description'
        }
        It 'falls back to System.Description for an unmapped type' {
            Resolve-AzdoBodyField -Config $script:cfg -Type 'Epic' | Should -Be 'System.Description'
        }
    }

    Context 'Build-AzdoPatch' {
        It 'builds add ops for title, body field, assignee, and extra fields' {
            $ops = Build-AzdoPatch -Title 'Hello' -Body '<p>Body</p>' -BodyField 'System.Description' `
                -AssignedTo 'a@b.com' -Fields @{ 'System.State' = 'New' }
            ($ops | Where-Object { $_.path -eq '/fields/System.Title' }).value | Should -Be 'Hello'
            ($ops | Where-Object { $_.path -eq '/fields/System.Description' }).value | Should -Be '<p>Body</p>'
            ($ops | Where-Object { $_.path -eq '/fields/System.AssignedTo' }).value | Should -Be 'a@b.com'
            ($ops | Where-Object { $_.path -eq '/fields/System.State' }).value | Should -Be 'New'
            ($ops | ForEach-Object { $_.op } | Select-Object -Unique) | Should -Be 'add'
        }
        It 'omits ops for parameters not provided' {
            $ops = Build-AzdoPatch -Body 'x' -BodyField 'System.Description'
            ($ops | Where-Object { $_.path -eq '/fields/System.Title' }) | Should -BeNullOrEmpty
            $ops.Count | Should -Be 1
        }
        It 'lets -Body win over a duplicate entry in -Fields and warns' {
            $w = $null
            $ops = Build-AzdoPatch -Body 'real' -BodyField 'System.Description' `
                -Fields @{ 'System.Description' = 'stale' } -WarningVariable w 3>$null
            ($ops | Where-Object { $_.path -eq '/fields/System.Description' }).value | Should -Be 'real'
            ($ops | Where-Object { $_.path -eq '/fields/System.Description' }).Count | Should -Be 1
            $w | Should -Not -BeNullOrEmpty
        }
    }
}
