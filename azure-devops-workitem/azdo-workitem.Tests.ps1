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
        It 'throws a clear error on update without an Id' {
            $env:TEST_FAKE_PAT = 'x'
            { Invoke-Main -Action update -Body 'x' -ConfigPath (Join-Path $script:cfgDir '.azuredevops.json') -DryRun } |
                Should -Throw '*-Id is required for update*'
            Remove-Item Env:TEST_FAKE_PAT
        }
    }

    Context 'Invoke-AzdoAndVerify (mocked HTTP)' {
        It 'sends the plan, re-fetches, and returns id and url; warns on short body' {
            $plan = [pscustomobject]@{
                Method='POST'; Url='https://dev.azure.com/contoso/P/_apis/wit/workitems/%24Bug?api-version=7.1'
                ContentType='application/json-patch+json; charset=utf-8'
                Patch=@(); Json='[]'; BodyBytes=[byte[]]@(); BodyByteCount=0; BodyField='System.Description'
            }
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'POST' } -MockWith {
                [pscustomobject]@{ id = 999; fields = [pscustomobject]@{ 'System.Description' = 'full body here' } }
            }
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' } -MockWith {
                [pscustomobject]@{ id = 999; fields = [pscustomobject]@{ 'System.Description' = 'full body here' } }
            }
            $env:TEST_FAKE_PAT = 'x'
            $r = Invoke-AzdoAndVerify -Plan $plan -PatEnvVar 'TEST_FAKE_PAT' -Org 'https://dev.azure.com/contoso' -Project 'P' -BodyField 'System.Description'
            $r.id | Should -Be 999
            $r.url | Should -Match '/_workitems/edit/999'
            Should -Invoke Invoke-RestMethod -Times 2
            Remove-Item Env:TEST_FAKE_PAT
        }
        It 'surfaces a clear error on a non-2xx response' {
            $plan = [pscustomobject]@{
                Method='POST'; Url='https://x/y?api-version=7.1'; ContentType='application/json-patch+json'
                Patch=@(); Json='[]'; BodyBytes=[byte[]]@(); BodyByteCount=0; BodyField='System.Description'
            }
            Mock Invoke-RestMethod { throw [System.Exception]::new('Remote 400: TF401320 invalid field') }
            $env:TEST_FAKE_PAT = 'x'
            { Invoke-AzdoAndVerify -Plan $plan -PatEnvVar 'TEST_FAKE_PAT' -Org 'https://x' -Project 'y' -BodyField 'System.Description' } |
                Should -Throw '*TF401320*'
            Remove-Item Env:TEST_FAKE_PAT
        }
        It 'does not throw when the re-fetch omits the body field (ADO omits empty fields)' {
            # Regression: StrictMode dot-access on a missing field must not blow up AFTER a good write.
            $plan = [pscustomobject]@{
                Method='POST'; Url='https://dev.azure.com/contoso/P/_apis/wit/workitems/%24Bug?api-version=7.1'
                ContentType='application/json-patch+json; charset=utf-8'
                Patch=@([pscustomobject]@{ op='add'; path='/fields/System.Description'; value='hello' })
                Json='[]'; BodyBytes=[byte[]]@(); BodyByteCount=0; BodyField='System.Description'
            }
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'POST' } -MockWith { [pscustomobject]@{ id = 7 } }
            # Re-fetch returns a fields bag WITHOUT System.Description (and without Title/State).
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' } -MockWith {
                [pscustomobject]@{ id = 7; fields = [pscustomobject]@{ 'System.WorkItemType' = 'Bug' } }
            }
            $env:TEST_FAKE_PAT = 'x'
            $r = Invoke-AzdoAndVerify -Plan $plan -PatEnvVar 'TEST_FAKE_PAT' -Org 'https://dev.azure.com/contoso' -Project 'P' -BodyField 'System.Description'
            $r.id | Should -Be 7
            $r.type | Should -Be 'Bug'
            $r.title | Should -BeNullOrEmpty
            Remove-Item Env:TEST_FAKE_PAT
        }
        It 'warns on gross body loss (truncation)' {
            $long = 'x' * 200
            $plan = [pscustomobject]@{
                Method='POST'; Url='https://dev.azure.com/contoso/P/_apis/wit/workitems/%24Bug?api-version=7.1'
                ContentType='application/json-patch+json; charset=utf-8'
                Patch=@([pscustomobject]@{ op='add'; path='/fields/System.Description'; value=$long })
                Json='[]'; BodyBytes=[byte[]]@(); BodyByteCount=0; BodyField='System.Description'
            }
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'POST' } -MockWith { [pscustomobject]@{ id = 8 } }
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' } -MockWith {
                [pscustomobject]@{ id = 8; fields = [pscustomobject]@{ 'System.Description' = 'tiny' } }  # 4 chars vs 200
            }
            $env:TEST_FAKE_PAT = 'x'; $w = $null
            $r = Invoke-AzdoAndVerify -Plan $plan -PatEnvVar 'TEST_FAKE_PAT' -Org 'https://dev.azure.com/contoso' -Project 'P' -BodyField 'System.Description' -WarningVariable w 3>$null
            $r.id | Should -Be 8
            ($w -join ' ') | Should -Match 'truncation'
            Remove-Item Env:TEST_FAKE_PAT
        }
        It 'still returns id and url when the verification re-fetch fails' {
            # A transient failure on the verify GET must not fail a successful write.
            $plan = [pscustomobject]@{
                Method='POST'; Url='https://dev.azure.com/contoso/P/_apis/wit/workitems/%24Bug?api-version=7.1'
                ContentType='application/json-patch+json; charset=utf-8'
                Patch=@(); Json='[]'; BodyBytes=[byte[]]@(); BodyByteCount=0; BodyField='System.Description'
            }
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'POST' } -MockWith { [pscustomobject]@{ id = 42 } }
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'Get' } -MockWith { throw [System.Exception]::new('503 throttled') }
            $env:TEST_FAKE_PAT = 'x'; $w = $null
            $r = Invoke-AzdoAndVerify -Plan $plan -PatEnvVar 'TEST_FAKE_PAT' -Org 'https://dev.azure.com/contoso' -Project 'P' -BodyField 'System.Description' -WarningVariable w 3>$null
            $r.id | Should -Be 42
            $r.url | Should -Match '/_workitems/edit/42'
            ($w -join ' ') | Should -Match 'verification re-fetch failed'
            Remove-Item Env:TEST_FAKE_PAT
        }
        It 'throws if the write response has no id' {
            $plan = [pscustomobject]@{
                Method='POST'; Url='https://dev.azure.com/contoso/P/_apis/wit/workitems/%24Bug?api-version=7.1'
                ContentType='application/json-patch+json; charset=utf-8'
                Patch=@(); Json='[]'; BodyBytes=[byte[]]@(); BodyByteCount=0; BodyField='System.Description'
            }
            Mock Invoke-RestMethod -ParameterFilter { $Method -eq 'POST' } -MockWith { [pscustomobject]@{ somethingElse = 1 } }
            $env:TEST_FAKE_PAT = 'x'
            { Invoke-AzdoAndVerify -Plan $plan -PatEnvVar 'TEST_FAKE_PAT' -Org 'https://dev.azure.com/contoso' -Project 'P' -BodyField 'System.Description' } |
                Should -Throw '*no work-item id*'
            Remove-Item Env:TEST_FAKE_PAT
        }
    }
}
