$env:PAD_BACKUP_RESTORE_TEST_MODE = '1'
. "$PSScriptRoot\..\pad-backup-restore.ps1"

Describe 'Get-WorkspaceCopyPlan' {
    It 'prefers PADDebuggerTemp when a live script exists there' {
        $root = Join-Path $env:TEMP ('pad-test-' + [guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $root -Force | Out-Null

        try {
            $workspaceRoot = Join-Path $root 'workspace-flow'
            $workspacePackage = Join-Path $workspaceRoot '1DE9DF00'
            $debuggerRoot = Join-Path $root 'debugger-flow'
            New-Item -ItemType Directory -Path $workspacePackage -Force | Out-Null
            New-Item -ItemType Directory -Path $debuggerRoot -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $workspacePackage 'script.robin') -Value 'old'
            Set-Content -LiteralPath (Join-Path $debuggerRoot 'script.robin') -Value 'new'

            $plan = Get-WorkspaceCopyPlan -WorkspacePath $workspaceRoot -DebuggerTempPath $debuggerRoot

            $plan.Status | Should Be 'DebuggerTemp'
            $plan.IncludeWorkspace | Should Be $true
            $plan.SourcePath | Should Be $debuggerRoot
            $plan.ExportRootName | Should Be '1DE9DF00'
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'falls back to Console Workspace when PADDebuggerTemp is missing' {
        $root = Join-Path $env:TEMP ('pad-test-' + [guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $root -Force | Out-Null

        try {
            $workspaceRoot = Join-Path $root 'workspace-flow'
            $workspacePackage = Join-Path $workspaceRoot '1DE9DF00'
            New-Item -ItemType Directory -Path $workspacePackage -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $workspacePackage 'script.robin') -Value 'old'

            $plan = Get-WorkspaceCopyPlan -WorkspacePath $workspaceRoot -DebuggerTempPath (Join-Path $root 'missing-debugger')

            $plan.Status | Should Be 'Workspace'
            $plan.IncludeWorkspace | Should Be $true
            $plan.SourcePath | Should Be $workspacePackage
            $plan.ExportRootName | Should Be '1DE9DF00'
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

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
