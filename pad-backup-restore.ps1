param()

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Web.Extensions
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:Serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$script:Serializer.MaxJsonLength = 134217728
$script:ToolDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:PadBase = Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop'
$script:DesignerDir = Join-Path $script:PadBase 'Designer\Data'
$script:WorkspaceDir = Join-Path $script:PadBase 'Console\Workspace'
$script:ScriptsDir = Join-Path $script:PadBase 'Console\Scripts'
$script:AuthoringDir = Join-Path $script:PadBase 'Cache\Store\Authoring'
$script:DebuggerTempDir = Join-Path $env:LOCALAPPDATA 'Temp\PADDebuggerTemp'
$script:DesignerTempDir = Join-Path $script:PadBase 'Designer\Temp'

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor DarkGray
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ('=' * 60) -ForegroundColor DarkGray
}

function Read-Answer {
    param([string]$Prompt)
    $value = Read-Host $Prompt
    if ($null -eq $value) {
        return ''
    }
    return $value.Trim()
}

function Get-Sha256Hex {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('X2') }) -join '')
    }
    finally {
        $sha.Dispose()
    }
}

function Write-Utf8File {
    param(
        [string]$Path,
        [string]$Content
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Unprotect-JsonText {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $bytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    return [System.Text.Encoding]::UTF8.GetString($plain)
}

function Protect-JsonText {
    param(
        [string]$Text,
        [string]$Path
    )
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $protected = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::CurrentUser
    )
    [System.IO.File]::WriteAllBytes($Path, $protected)
}

function Read-ProtectedJson {
    param([string]$Path)
    return $script:Serializer.DeserializeObject((Unprotect-JsonText -Path $Path))
}

function Save-PlainJson {
    param(
        [object]$Object,
        [string]$Path
    )
    Write-Utf8File -Path $Path -Content ($script:Serializer.Serialize($Object))
}

function Read-PlainJson {
    param([string]$Path)
    return $script:Serializer.DeserializeObject([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8))
}

function Stop-PadBackgroundHost {
    $hostProcesses = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -eq 'PAD.BrowserNativeMessageHost'
    }
    if ($hostProcesses) {
        $hostProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    }
}

function Assert-PadClosed {
    Stop-PadBackgroundHost
    $padProcesses = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        ($_.ProcessName -like '*PowerAutomate*' -or $_.ProcessName -eq 'PAD.Console.Host') -and $_.MainWindowTitle
    }
    if ($padProcesses) {
        throw "运行前请先完全关闭 Power Automate Desktop"
    }
}

function Get-CachePaths {
    param([string]$FlowId)

    $fullHash = Get-Sha256Hex ('workflow-full-package-' + $FlowId)
    $partialHash = Get-Sha256Hex ('workflow-partial-package-' + $FlowId)

    return @{
        FullBin = Join-Path $script:AuthoringDir ('cacheFile_' + $fullHash + '.bin')
        FullMeta = Join-Path $script:AuthoringDir ('cacheFile_' + $fullHash + '.meta.bin')
        PartialBin = Join-Path $script:AuthoringDir ('cacheFile_' + $partialHash + '.bin')
        PartialMeta = Join-Path $script:AuthoringDir ('cacheFile_' + $partialHash + '.meta.bin')
    }
}

function Get-FlowNameFromMetadataCache {
    param([string]$FlowId)

    $metaFiles = Get-ChildItem -LiteralPath $script:AuthoringDir -Filter '*.meta.bin' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending

    foreach ($metaFile in $metaFiles) {
        try {
            $metaObj = Read-ProtectedJson -Path $metaFile.FullName
            $key = [string]$metaObj['Key']
            if (-not $key -or $key -notlike '*:flowMetadata') {
                continue
            }

            $binPath = $metaFile.FullName -replace '\.meta\.bin$', '.bin'
            if (-not (Test-Path $binPath)) {
                continue
            }

            $binObj = Read-ProtectedJson -Path $binPath
            $value = $binObj['Value']
            if ($value -and [string]$value['id'] -eq $FlowId) {
                return [string]$value['name']
            }
        }
        catch {
        }
    }

    return ''
}

function Get-FlowName {
    param([string]$FlowId)

    $cachePaths = Get-CachePaths -FlowId $FlowId
    if (-not (Test-Path $cachePaths.FullBin)) {
        return (Get-FlowNameFromMetadataCache -FlowId $FlowId)
    }

    try {
        $fullObj = Read-ProtectedJson -Path $cachePaths.FullBin
        $name = [string]$fullObj['Value']['Name']
        if ($name) {
            return $name
        }
    }
    catch {
    }

    return (Get-FlowNameFromMetadataCache -FlowId $FlowId)
}

function Get-FlowList {
    if (-not (Test-Path $script:DesignerDir)) {
        throw '未找到 Designer\\Data 目录'
    }

    $settingsFiles = Get-ChildItem -LiteralPath $script:DesignerDir -Filter '*.settings' |
        Sort-Object LastWriteTime -Descending

    $index = 0
    $flows = foreach ($file in $settingsFiles) {
        $index++
        $flowId = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        [pscustomobject]@{
            No = $index
            FlowId = $flowId
            Name = (Get-FlowName -FlowId $flowId)
            LastWriteTime = $file.LastWriteTime
            Size = $file.Length
        }
    }
    return $flows
}

function Show-FlowList {
    param([object[]]$Flows)

    if (-not $Flows) {
        throw '没有找到 PAD 自动化 请先新建空白流'
    }

    Write-Host ''
    Write-Host '可选自动化列表' -ForegroundColor Cyan
    foreach ($flow in $Flows) {
        $name = if ([string]::IsNullOrWhiteSpace($flow.Name)) { '<未命名>' } else { $flow.Name }
        $line = '{0,2}. {1} | {2} | {3:yyyy-MM-dd HH:mm:ss}' -f $flow.No, $name, $flow.FlowId, $flow.LastWriteTime
        Write-Host $line
    }
}

function Select-Flow {
    param([string]$Prompt = '请输入序号 或直接粘贴 Flow ID')

    $flows = Get-FlowList
    Show-FlowList -Flows $flows

    while ($true) {
        $answer = Read-Answer -Prompt $Prompt
        if (-not $answer) {
            continue
        }

        if ($answer -match '^\d+$') {
            $selected = $flows | Where-Object { $_.No -eq [int]$answer } | Select-Object -First 1
            if ($selected) {
                return $selected
            }
        }
        else {
            $selected = $flows | Where-Object { $_.FlowId -eq $answer } | Select-Object -First 1
            if ($selected) {
                return $selected
            }
        }

        Write-Host '选择无效 请重新输入' -ForegroundColor Yellow
    }
}

function New-TempDir {
    param([string]$Prefix)
    $path = Join-Path $env:TEMP ($Prefix + '-' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Copy-DirectoryContents {
    param(
        [string]$Source,
        [string]$Destination
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $children = Get-ChildItem -LiteralPath $Source -Force
    foreach ($child in $children) {
        Copy-Item -LiteralPath $child.FullName -Destination $Destination -Recurse -Force
    }
}

function Get-WorkspaceSnapshotState {
    param(
        [string]$SettingsPath,
        [string]$WorkspacePath,
        [string]$FullPackagePath
    )

    if (-not (Test-Path $WorkspacePath)) {
        return [pscustomobject]@{
            Status = 'Missing'
            IncludeWorkspace = $false
            WorkspaceWriteTime = $null
            ReferenceWriteTime = $null
        }
    }

    return [pscustomobject]@{
        Status = 'Present'
        IncludeWorkspace = $true
        WorkspaceWriteTime = $null
        ReferenceWriteTime = $null
    }
}

function Get-WorkspaceCopyPlan {
    param(
        [string]$WorkspacePath,
        [string]$DebuggerTempPath,
        [string]$DesignerTempRoot
    )

    $workspacePackage = $null
    $workspacePackageName = ''
    if (Test-Path $WorkspacePath) {
        $packageDirs = Get-ChildItem -LiteralPath $WorkspacePath -Directory -Force -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
        if ($packageDirs -and $packageDirs.Count -gt 0) {
            $workspacePackage = $packageDirs[0].FullName
            $workspacePackageName = $packageDirs[0].Name
        }
    }

    $debuggerScript = Join-Path $DebuggerTempPath 'script.robin'
    $designerTempDir = $null
    if (Test-Path $DesignerTempRoot) {
        $designerTempDir = Get-ChildItem -LiteralPath $DesignerTempRoot -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { Test-Path (Join-Path $_.FullName 'script.robin') } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    }

    if ($designerTempDir) {
        return [pscustomobject]@{
            Status = 'DesignerTemp'
            IncludeWorkspace = $true
            SourcePath = $designerTempDir.FullName
            ExportRootName = if ($workspacePackageName) { $workspacePackageName } else { '1DE9DF00' }
        }
    }

    if (Test-Path $debuggerScript) {
        return [pscustomobject]@{
            Status = 'DebuggerTemp'
            IncludeWorkspace = $true
            SourcePath = $DebuggerTempPath
            ExportRootName = if ($workspacePackageName) { $workspacePackageName } else { '1DE9DF00' }
        }
    }

    if ($workspacePackage) {
        return [pscustomobject]@{
            Status = 'Workspace'
            IncludeWorkspace = $true
            SourcePath = $workspacePackage
            ExportRootName = $workspacePackageName
        }
    }

    return [pscustomobject]@{
        Status = 'Missing'
        IncludeWorkspace = $false
        SourcePath = $null
        ExportRootName = ''
    }
}

function Get-PortableBackups {
    $zipFiles = Get-ChildItem -LiteralPath $script:ToolDir -Filter '*.zip' |
        Sort-Object LastWriteTime -Descending

    $index = 0
    $items = New-Object System.Collections.Generic.List[object]

    foreach ($zip in $zipFiles) {
        try {
            $archive = [System.IO.Compression.ZipFile]::OpenRead($zip.FullName)
            try {
                $manifestEntry = $archive.Entries | Where-Object { $_.FullName -eq 'manifest.json' } | Select-Object -First 1
                if (-not $manifestEntry) {
                    continue
                }

                $reader = New-Object System.IO.StreamReader($manifestEntry.Open(), [System.Text.Encoding]::UTF8)
                try {
                    $manifestText = $reader.ReadToEnd()
                }
                finally {
                    $reader.Dispose()
                }

                $manifest = $script:Serializer.DeserializeObject($manifestText)
                if ($manifest['Format'] -ne 'PADPortableBackup' -or $manifest['Version'] -ne 1) {
                    continue
                }

                $index++
                $items.Add([pscustomobject]@{
                    No = $index
                    FileName = $zip.Name
                    FullName = $zip.FullName
                    BackupTime = $manifest['CreatedAt']
                    SourceFlowId = $manifest['SourceFlowId']
                    SourceFlowName = $manifest['SourceFlowName']
                })
            }
            finally {
                $archive.Dispose()
            }
        }
        catch {
        }
    }

    return $items
}

function Select-BackupZip {
    $backups = Get-PortableBackups
    if (-not $backups -or $backups.Count -eq 0) {
        throw ('当前目录没有找到可用备份 zip ' + $script:ToolDir)
    }

    Write-Host ''
    Write-Host '可选备份包' -ForegroundColor Cyan
    foreach ($backup in $backups) {
        $name = if ([string]::IsNullOrWhiteSpace($backup.SourceFlowName)) { '<未命名>' } else { $backup.SourceFlowName }
        $line = '{0,2}. {1} | {2} | {3} | {4}' -f $backup.No, $name, $backup.SourceFlowId, $backup.BackupTime, $backup.FileName
        Write-Host $line
    }

    while ($true) {
        $answer = Read-Answer -Prompt '请输入备份包序号'
        if ($answer -match '^\d+$') {
            $selected = $backups | Where-Object { $_.No -eq [int]$answer } | Select-Object -First 1
            if ($selected) {
                return $selected
            }
        }

        Write-Host '选择无效 请重新输入' -ForegroundColor Yellow
    }
}

function Backup-Flow {
    Assert-PadClosed
    Write-Section '备份自动化'

    $flow = Select-Flow -Prompt '请选择要备份的自动化'
    $cachePaths = Get-CachePaths -FlowId $flow.FlowId

    $settingsPath = Join-Path $script:DesignerDir ($flow.FlowId + '.settings')
    $workspacePath = Join-Path $script:WorkspaceDir $flow.FlowId
    $debuggerTempPath = Join-Path $script:DebuggerTempDir $flow.FlowId
    $designerTempRoot = $script:DesignerTempDir
    $scriptsPath = Join-Path $script:ScriptsDir $flow.FlowId

    if (-not (Test-Path $settingsPath)) {
        throw '所选自动化缺少 settings 文件'
    }
    if (-not (Test-Path $cachePaths.FullBin) -or -not (Test-Path $cachePaths.FullMeta)) {
        throw '所选自动化缺少 full-package 缓存'
    }

    $workspaceState = Get-WorkspaceSnapshotState -SettingsPath $settingsPath -WorkspacePath $workspacePath -FullPackagePath $cachePaths.FullBin
    $workspacePlan = Get-WorkspaceCopyPlan -WorkspacePath $workspacePath -DebuggerTempPath $debuggerTempPath -DesignerTempRoot $designerTempRoot

    $tempRoot = New-TempDir -Prefix 'pad-portable-backup'
    try {
        $settingsExport = Join-Path $tempRoot 'settings'
        $workspaceExport = Join-Path $tempRoot 'workspace'
        $scriptsExport = Join-Path $tempRoot 'scripts'
        New-Item -ItemType Directory -Path $settingsExport -Force | Out-Null

        Copy-Item -LiteralPath $settingsPath -Destination (Join-Path $settingsExport 'flow.settings') -Force
        $hasWorkspace = $false
        if ($workspacePlan.IncludeWorkspace) {
            New-Item -ItemType Directory -Path $workspaceExport -Force | Out-Null
            $workspaceDestination = if ($workspacePlan.ExportRootName) {
                Join-Path $workspaceExport $workspacePlan.ExportRootName
            }
            else {
                $workspaceExport
            }
            Copy-DirectoryContents -Source $workspacePlan.SourcePath -Destination $workspaceDestination
            $hasWorkspace = $true
        }

        $fullObj = Read-ProtectedJson -Path $cachePaths.FullBin
        $fullMetaObj = Read-ProtectedJson -Path $cachePaths.FullMeta
        Save-PlainJson -Object $fullObj -Path (Join-Path $tempRoot 'full-package.json')
        Save-PlainJson -Object $fullMetaObj -Path (Join-Path $tempRoot 'full-package.meta.json')

        $hasPartial = $false
        if ((Test-Path $cachePaths.PartialBin) -and (Test-Path $cachePaths.PartialMeta)) {
            $partialObj = Read-ProtectedJson -Path $cachePaths.PartialBin
            $partialMetaObj = Read-ProtectedJson -Path $cachePaths.PartialMeta
            Save-PlainJson -Object $partialObj -Path (Join-Path $tempRoot 'partial-package.json')
            Save-PlainJson -Object $partialMetaObj -Path (Join-Path $tempRoot 'partial-package.meta.json')
            $hasPartial = $true
        }

        $hasScripts = $false
        if (Test-Path $scriptsPath) {
            New-Item -ItemType Directory -Path $scriptsExport -Force | Out-Null
            Copy-DirectoryContents -Source $scriptsPath -Destination $scriptsExport
            $hasScripts = $true
        }

        $manifest = @{
            Format = 'PADPortableBackup'
            Version = 1
            CreatedAt = (Get-Date).ToString('o')
            SourceFlowId = $flow.FlowId
            SourceFlowName = $flow.Name
            HasWorkspace = $hasWorkspace
            WorkspaceStatus = $workspacePlan.Status
            HasPartialPackage = $hasPartial
            HasScripts = $hasScripts
            Tool = 'pad-backup-restore.ps1'
        }
        Save-PlainJson -Object $manifest -Path (Join-Path $tempRoot 'manifest.json')

        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $zipPath = Join-Path $script:ToolDir ($flow.FlowId + '_' + $timestamp + '.zip')
        if (Test-Path $zipPath) {
            Remove-Item -LiteralPath $zipPath -Force
        }

        Compress-Archive -Path (Join-Path $tempRoot '*') -DestinationPath $zipPath -Force

        Write-Host ''
        Write-Host '备份完成' -ForegroundColor Green
        Write-Host ('自动化名称 ' + $flow.Name)
        Write-Host ('自动化 ID ' + $flow.FlowId)
        Write-Host ('备份文件 ' + $zipPath)
        if (-not $hasWorkspace) {
            Write-Host '提示 当前自动化没有可用 workspace 已仅备份 full-package/settings' -ForegroundColor Yellow
        }
    }
    finally {
        if (Test-Path $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Restore-Flow {
    Assert-PadClosed
    Write-Section '恢复自动化'

    $backup = Select-BackupZip
    $targetFlow = Select-Flow -Prompt '请选择要恢复到的目标自动化'

    $tempRoot = New-TempDir -Prefix 'pad-portable-restore'
    try {
        Expand-Archive -LiteralPath $backup.FullName -DestinationPath $tempRoot -Force

        $manifestPath = Join-Path $tempRoot 'manifest.json'
        if (-not (Test-Path $manifestPath)) {
            throw '所选备份包不包含 manifest.json'
        }

        $manifest = Read-PlainJson -Path $manifestPath
        if ($manifest['Format'] -ne 'PADPortableBackup' -or $manifest['Version'] -ne 1) {
            throw '所选备份包不是受支持的 PAD 备份格式'
        }

        $settingsSource = Join-Path $tempRoot 'settings\flow.settings'
        $workspaceSource = Join-Path $tempRoot 'workspace'
        $scriptsSource = Join-Path $tempRoot 'scripts'
        $fullJsonPath = Join-Path $tempRoot 'full-package.json'
        $fullMetaJsonPath = Join-Path $tempRoot 'full-package.meta.json'
        $partialJsonPath = Join-Path $tempRoot 'partial-package.json'
        $partialMetaJsonPath = Join-Path $tempRoot 'partial-package.meta.json'

        if (-not (Test-Path $settingsSource)) {
            throw '备份包缺少 settings\\flow.settings'
        }
        if (-not (Test-Path $fullJsonPath) -or -not (Test-Path $fullMetaJsonPath)) {
            throw '备份包缺少 full-package 数据'
        }

        $targetSettings = Join-Path $script:DesignerDir ($targetFlow.FlowId + '.settings')
        $targetWorkspace = Join-Path $script:WorkspaceDir $targetFlow.FlowId
        $targetScripts = Join-Path $script:ScriptsDir $targetFlow.FlowId
        $targetCache = Get-CachePaths -FlowId $targetFlow.FlowId

        $targetFlowName = Get-FlowName -FlowId $targetFlow.FlowId
        if (-not $targetFlowName) {
            $targetFlowName = [string]$manifest['SourceFlowName']
        }

        Copy-Item -LiteralPath $settingsSource -Destination $targetSettings -Force

        if (Test-Path $targetWorkspace) {
            Remove-Item -LiteralPath $targetWorkspace -Recurse -Force
        }
        $backupHasWorkspace = $true
        if ($manifest.ContainsKey('HasWorkspace')) {
            $backupHasWorkspace = [bool]$manifest['HasWorkspace']
        }
        elseif (-not (Test-Path $workspaceSource)) {
            $backupHasWorkspace = $false
        }
        if ($backupHasWorkspace -and (Test-Path $workspaceSource)) {
            Copy-DirectoryContents -Source $workspaceSource -Destination $targetWorkspace
        }

        if (Test-Path $targetScripts) {
            Remove-Item -LiteralPath $targetScripts -Recurse -Force
        }
        if (Test-Path $scriptsSource) {
            Copy-DirectoryContents -Source $scriptsSource -Destination $targetScripts
        }

        $fullMetaObj = Read-PlainJson -Path $fullMetaJsonPath
        $fullMetaObj['Timestamp'] = (Get-Date).ToUniversalTime().ToString('o')
        $fullMetaObj['Key'] = 'workflow-full-package-' + $targetFlow.FlowId
        $fullMetaObj['ExpirationTag'] = $null
        Protect-JsonText -Text ($script:Serializer.Serialize($fullMetaObj)) -Path $targetCache.FullMeta

        $fullObj = Read-PlainJson -Path $fullJsonPath
        $fullObj['Timestamp'] = (Get-Date).ToUniversalTime().ToString('o')
        $fullObj['Value']['WorkflowId'] = $targetFlow.FlowId
        $fullObj['Value']['Name'] = $targetFlowName
        $fullObj['Value']['ETag'] = ''
        Protect-JsonText -Text ($script:Serializer.Serialize($fullObj)) -Path $targetCache.FullBin

        if ((Test-Path $partialJsonPath) -and (Test-Path $partialMetaJsonPath)) {
            $partialMetaObj = Read-PlainJson -Path $partialMetaJsonPath
            $partialMetaObj['Timestamp'] = (Get-Date).ToUniversalTime().ToString('o')
            $partialMetaObj['Key'] = 'workflow-partial-package-' + $targetFlow.FlowId
            $partialMetaObj['ExpirationTag'] = $null
            Protect-JsonText -Text ($script:Serializer.Serialize($partialMetaObj)) -Path $targetCache.PartialMeta

            $partialObj = Read-PlainJson -Path $partialJsonPath
            $partialObj['Timestamp'] = (Get-Date).ToUniversalTime().ToString('o')
            if ($partialObj['Value'] -and $partialObj['Value']['Flow']) {
                $partialObj['Value']['Flow']['Id'] = $targetFlow.FlowId
                $partialObj['Value']['Flow']['Name'] = $targetFlowName
            }
            Protect-JsonText -Text ($script:Serializer.Serialize($partialObj)) -Path $targetCache.PartialBin
        }

        $debuggerTemp = Join-Path $env:LOCALAPPDATA ('Temp\PADDebuggerTemp\' + $targetFlow.FlowId)
        if (Test-Path $debuggerTemp) {
            Remove-Item -LiteralPath $debuggerTemp -Recurse -Force
        }

        Write-Host ''
        Write-Host '恢复完成' -ForegroundColor Green
        Write-Host ('备份包 ' + $backup.FileName)
        Write-Host ('来源自动化 ' + $manifest['SourceFlowName'] + ' [' + $manifest['SourceFlowId'] + ']')
        Write-Host ('目标自动化 ' + $targetFlowName + ' [' + $targetFlow.FlowId + ']')
        if (-not $backupHasWorkspace) {
            Write-Host '提示 本备份包未恢复 workspace 将以 full-package 为准' -ForegroundColor Yellow
        }
        Write-Host ''
        Write-Host '下一步建议' -ForegroundColor Cyan
        Write-Host '1. 打开 Power Automate Desktop'
        Write-Host '2. 进入目标自动化'
        Write-Host '3. 确认内容正常后手动保存一次'
    }
    finally {
        if (Test-Path $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Show-MainMenu {
    Write-Section 'PAD 备份恢复工具'
    Write-Host '1. 备份自动化'
    Write-Host '2. 从备份包恢复'
    Write-Host 'Q. 退出'
    Write-Host ''
}

if (-not $env:PAD_BACKUP_RESTORE_TEST_MODE) {
    try {
        while ($true) {
            Show-MainMenu
            $choice = (Read-Answer -Prompt '请选择功能').ToUpperInvariant()

            switch ($choice) {
                '1' {
                    Backup-Flow
                }
                '2' {
                    Restore-Flow
                }
                'Q' {
                    break
                }
                default {
                    Write-Host '输入无效 请重新选择' -ForegroundColor Yellow
                    continue
                }
            }

            Write-Host ''
            $again = (Read-Answer -Prompt '按回车返回主菜单 或输入 Q 退出').ToUpperInvariant()
            if ($again -eq 'Q') {
                break
            }
        }
    }
    catch {
        Write-Host ''
        Write-Host '发生错误' -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
    finally {
        Write-Host ''
        Read-Answer -Prompt '按回车关闭窗口' | Out-Null
    }
}
