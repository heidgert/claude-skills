BeforeAll {
    # Dot-source the script to load its functions without executing Main.
    . "$PSScriptRoot/azdo-workitem.ps1"
}

Describe 'azdo-workitem' {
    It 'loads without executing Main' {
        Get-Command Invoke-Main -ErrorAction Stop | Should -Not -BeNullOrEmpty
    }
}
