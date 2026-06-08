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

    Context 'New-AzdoRequestPlan' {
        BeforeAll {
            $script:ops = ,([pscustomobject]@{ op = 'add'; path = '/fields/System.Title'; value = 'Tä' })
        }
        It 'builds a create URL with the encoded type segment' {
            $plan = New-AzdoRequestPlan -Action create -Org 'https://dev.azure.com/contoso' `
                -Project 'My Proj' -Type 'Product Backlog Item' -Patch $script:ops
            $plan.Method | Should -Be 'POST'
            $plan.Url | Should -Be 'https://dev.azure.com/contoso/My%20Proj/_apis/wit/workitems/%24Product%20Backlog%20Item?api-version=7.1'
            $plan.ContentType | Should -Match 'json-patch'
        }
        It 'serializes a multi-op patch as a flat JSON array (not double-wrapped)' {
            $multi = @(
                [pscustomobject]@{ op = 'add'; path = '/fields/System.Title'; value = 'T' }
                [pscustomobject]@{ op = 'add'; path = '/fields/System.State'; value = 'New' }
            )
            $plan = New-AzdoRequestPlan -Action create -Org 'https://dev.azure.com/contoso' `
                -Project 'P' -Type 'Bug' -Patch $multi
            # Must be [ {..}, {..} ] — a 2-element array of op objects, not [[..]] (1 element
            # that is itself an array, which is what the old -InputObject form produced).
            $plan.Json.TrimStart()[0] | Should -Be '['
            $parsed = $plan.Json | ConvertFrom-Json
            $parsed.Count | Should -Be 2          # double-wrapped [[..]] would parse to Count 1
            $parsed[0].op | Should -Be 'add'      # top-level element is an op object, not an array
            $parsed[0].path | Should -Be '/fields/System.Title'
        }
        It 'builds an update URL with the id' {
            $plan = New-AzdoRequestPlan -Action update -Org 'https://dev.azure.com/contoso' `
                -Project 'My Proj' -Id 4321 -Patch $script:ops
            $plan.Method | Should -Be 'PATCH'
            $plan.Url | Should -Be 'https://dev.azure.com/contoso/My%20Proj/_apis/wit/workitems/4321?api-version=7.1'
        }
        It 'encodes the body as UTF-8 bytes that round-trip Swedish characters' {
            $plan = New-AzdoRequestPlan -Action create -Org 'https://dev.azure.com/contoso' `
                -Project 'P' -Type 'Bug' -Patch (,([pscustomobject]@{ op='add'; path='/fields/X'; value='åäö' }))
            $decoded = [System.Text.Encoding]::UTF8.GetString($plan.BodyBytes)
            $decoded | Should -Match 'åäö'
            $plan.BodyByteCount | Should -Be $plan.BodyBytes.Length
            # The body must NOT start with a UTF-8 BOM (EF BB BF) — a BOM would corrupt the JSON
            # that Invoke-RestMethod sends raw. This is the core anti-mojibake guarantee.
            ($plan.BodyBytes[0] -eq 0xEF -and $plan.BodyBytes[1] -eq 0xBB -and $plan.BodyBytes[2] -eq 0xBF) | Should -BeFalse
        }
    }

    Context 'Get-AzdoAuthHeader' {
        It 'builds a Basic header from the PAT env var' {
            $env:TEST_FAKE_PAT = 'secret123'
            $h = Get-AzdoAuthHeader -PatEnvVar 'TEST_FAKE_PAT'
            $h.Authorization | Should -Match '^Basic '
            $decoded = [System.Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($h.Authorization.Substring(6)))
            $decoded | Should -Be ':secret123'
            Remove-Item Env:TEST_FAKE_PAT
        }
        It 'throws when the PAT env var is missing or empty' {
            { Get-AzdoAuthHeader -PatEnvVar 'DEFINITELY_NOT_SET_PAT_XYZ' } | Should -Throw '*DEFINITELY_NOT_SET_PAT_XYZ*'
        }
    }

    Context 'Invoke-Main -DryRun' {
        BeforeAll {
            $script:cfgDir = Join-Path ([System.IO.Path]::GetTempPath()) ("azdodry_" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Force -Path $script:cfgDir | Out-Null
            @{
                org = 'https://dev.azure.com/contoso'; project = 'Proj'; patEnvVar = 'TEST_FAKE_PAT'
                defaultType = 'Bug'; bodyFieldByType = @{ Bug = 'Microsoft.VSTS.TCM.ReproSteps' }
                defaultAssignee = 'a@b.com'
            } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:cfgDir '.azuredevops.json') -Encoding utf8
        }
        AfterAll { Remove-Item -Recurse -Force -LiteralPath $script:cfgDir }

        It 'prints a plan and sends nothing on create' {
            $env:TEST_FAKE_PAT = 'x'
            $out = Invoke-Main -Action create -Title 'Tëst' -Body 'Brödtext med åäö' `
                -ConfigPath (Join-Path $script:cfgDir '.azuredevops.json') -DryRun
            $out.Method | Should -Be 'POST'
            $out.BodyField | Should -Be 'Microsoft.VSTS.TCM.ReproSteps'
            ($out.Patch | Where-Object { $_.path -eq '/fields/Microsoft.VSTS.TCM.ReproSteps' }).value | Should -Be 'Brödtext med åäö'
            Remove-Item Env:TEST_FAKE_PAT
        }
    }
}
