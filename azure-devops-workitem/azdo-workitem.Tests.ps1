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
            { Resolve-AzdoConfig -StartDir $orphan } | Should -Throw '*.azuredevops.json*'
            Remove-Item -Recurse -Force -LiteralPath $orphan
        }
        It 'uses an explicit ConfigPath when given' {
            $cfg = Resolve-AzdoConfig -ConfigPath (Join-Path $script:tmp '.azuredevops.json')
            $cfg.project | Should -Be 'Proj'
        }
    }
}
