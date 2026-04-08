$env:PAD_BACKUP_RESTORE_TEST_MODE = '1'
. "$PSScriptRoot\..\pad-backup-restore.ps1"

Describe 'Get-WorkspaceSnapshotState' {
    It 'marks a missing workspace as optional' {
        $root = Join-Path $env:TEMP ('pad-test-' + [guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $root -Force | Out-Null

        try {
            $settingsPath = Join-Path $root 'flow.settings'
            $fullPackagePath = Join-Path $root 'full-package.bin'

            Set-Content -LiteralPath $settingsPath -Value 'settings'
            Set-Content -LiteralPath $fullPackagePath -Value 'full'

            $state = Get-WorkspaceSnapshotState -SettingsPath $settingsPath -WorkspacePath (Join-Path $root 'workspace') -FullPackagePath $fullPackagePath

            $state.Status | Should Be 'Missing'
            $state.IncludeWorkspace | Should Be $false
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'includes a workspace whenever it exists' {
        $root = Join-Path $env:TEMP ('pad-test-' + [guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $root -Force | Out-Null

        try {
            $settingsPath = Join-Path $root 'flow.settings'
            $fullPackagePath = Join-Path $root 'full-package.bin'
            $workspacePath = Join-Path $root 'workspace'
            $workspaceChild = Join-Path $workspacePath 'script.robin'

            New-Item -ItemType Directory -Path $workspacePath -Force | Out-Null
            Set-Content -LiteralPath $settingsPath -Value 'settings'
            Set-Content -LiteralPath $fullPackagePath -Value 'full'
            Set-Content -LiteralPath $workspaceChild -Value 'workspace'

            $state = Get-WorkspaceSnapshotState -SettingsPath $settingsPath -WorkspacePath $workspacePath -FullPackagePath $fullPackagePath

            $state.Status | Should Be 'Present'
            $state.IncludeWorkspace | Should Be $true
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
