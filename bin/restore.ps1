#Requires -Version 5.1
<#
.SYNOPSIS
    SyncKit 还原端：把收件箱（或转移包）里的包按 base 链序应用到目标目录。

.DESCRIPTION
    两种用法：

    1) 常规模式（本机已装本工具）
       .\bin\restore.ps1 -Project <项目ID>
       包放在 data\projects\<项目ID>\inbox\ ，应用后自动移入 inbox\applied\。

    2) 转移包模式（目标机未装本工具，包自带一套精简工具与配置）
       .\bin\restore.ps1 -Bundle D:\备份同步\sync-xxx-20260928-170000
       直接使用转移包内的 packages\ 与 data\ ，双击转移包里的 restore.bat 即走这条路。

    应用流程（可安全重复执行）：
        · 沿 base 链找到"接得上"的包，缺中间包 / 乱序会明确报出，不会应用错；
        · 先整包解压到临时目录、逐文件校验 SHA256，全部通过才落地；
        · 覆盖/新增文件、执行删除清单并清理变空目录；
        · 全量包额外做镜像清理，落在任何旧状态上都能完全对齐。

.PARAMETER Project
    项目 ID。省略时：常规模式需能从收件箱推断，转移包模式则取包内唯一的项目。

.PARAMETER Bundle
    转移包目录（含 bundle.json 的那个目录）。

.PARAMETER Plan
    只显示将应用哪些包，不做任何改动。

.PARAMETER TargetDir
    覆盖项目配置中的目标目录（临时还原到别处时用）。

.PARAMETER Force
    即使收件箱里有属于其它项目的包也继续应用。

.EXAMPLE
    .\bin\restore.ps1 -Project drive-backup -Plan
    .\bin\restore.ps1 -Project drive-backup
    .\bin\restore.ps1 -Bundle "D:\备份同步\sync-drive-backup-20260928-170000" -Plan
    .\bin\restore.ps1 -Project demo -TargetDir D:\临时还原
#>
[CmdletBinding()]
param(
    [string]$Project,
    [string]$Bundle,
    [switch]$Plan,
    [string]$TargetDir,
    [string]$Inbox,
    [switch]$Force,
    [string]$Config,
    [string]$LogFile
)

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $toolRoot 'lib\SyncKit.psm1') -Force

$code = 0
try {
    if ($LogFile) { Set-SyncLogFile -Path $LogFile }

    $mode = '常规'
    if ($Bundle) {
        $mode = '转移包'
        $bundleRoot = (Resolve-Path -LiteralPath $Bundle).Path
        if (-not (Test-Path -LiteralPath (Join-Path $bundleRoot 'bundle.json') -PathType Leaf)) {
            throw ('不是有效的转移包（缺少 bundle.json）：{0}' -f $bundleRoot)
        }
        if (-not $Config) { $Config = Join-Path $toolRoot 'projects.json' }
        if (-not $Inbox)  { $Inbox  = Join-Path $bundleRoot 'packages' }
        Write-Log -Message ('转移包模式：{0}' -f $bundleRoot) -Level 'STEP'
    }

    Write-Log -Message ('══ SyncKit {0} · 还原任务开始（{1} 模式）@{2} ══' -f (Get-SyncKitVersion), $mode, (Get-SyncHostName)) -Level 'STEP'
    if ($Plan) { Write-Log -Message '预览模式（-Plan）：不会写入任何文件' -Level 'WARN' }

    $cfg = Get-SyncConfig -Path $Config
    $proj = $null
    if ($Project) {
        $proj = Get-SyncProject -Config $cfg -Id $Project
    }
    else {
        $all = @($cfg.projects)
        if ($all.Count -eq 1) { $proj = $all[0] }
        elseif ($all.Count -eq 0) { throw 'projects.json 里没有任何项目，请用 -Project 指定或先配置项目。' }
        else {
            $ids = (@($all | ForEach-Object { $_.id }) -join ', ')
            throw ('有多个项目，请用 -Project 指定其中一个：{0}' -f $ids)
        }
    }
    Write-Log -Message ('项目：{0}（{1}）' -f $proj.name, $proj.id) -Level 'INFO'

    if (-not $TargetDir -and -not $proj.target) {
        throw ('项目 [{0}] 没有配置目标目录（target）。请在 projects.json 中填写，或用 -TargetDir 指定。' -f $proj.id)
    }

    $rc = Invoke-SyncRestore -Config $cfg -Project $proj -TargetDir $TargetDir -InboxDir $Inbox -Plan:$Plan -Force:$Force
    $code = [int]$rc

    if ($code -eq 0 -and -not $Plan) {
        Write-Log -Message '还原完成。' -Level 'OK'
    }
}
catch {
    Write-Log -Message ('还原任务失败：{0}' -f $_.Exception.Message) -Level 'ERROR'
    $code = 1
}
finally {
    Write-JobExit -Code $code
}
exit $code
