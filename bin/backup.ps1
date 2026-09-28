#Requires -Version 5.1
<#
.SYNOPSIS
    SyncKit 备份端：为一个或多个「项目」生成备份包（全量 F-*.zip / 增量 I-*.zip）。

.DESCRIPTION
    日常增量：直接运行，脚本会与上次快照比对（大小 + 精确 UTC 修改时间），
    只打包新增/修改的文件，并在包内记录删除清单，秒级完成。

    重新对齐：加 -Full 生成全量包（含全部文件，作为新链起点）。首次使用、
    状态丢失、或想彻底对齐时使用。

.PARAMETER Project
    项目 ID（在 projects.json 中配置）。省略 = 处理所有配置了源目录的项目。

.PARAMETER Full
    生成全量包。

.PARAMETER DryRun
    只预览将要打包 / 删除的文件，不生成包、不改动状态。

.PARAMETER Target
    生成后把包额外拷贝到该目录（U 盘、网络共享等）。包仍保留在 increments 里。

.PARAMETER Keep
    保留最近多少个包，更早的自动清理。-1（默认）= 用项目配置中的 keep。

.PARAMETER NoHook
    不执行项目配置里的 preCommand / postCommand（例如 docker pause）。

.EXAMPLE
    .\bin\backup.ps1                        # 全部项目：增量备份
    .\bin\backup.ps1 -Project verdaccio     # 指定项目：增量备份
    .\bin\backup.ps1 -Project verdaccio -Full
    .\bin\backup.ps1 -DryRun                # 预览各项目的差异
    .\bin\backup.ps1 -Target E:\            # 生成后拷到 U 盘
#>
[CmdletBinding()]
param(
    [string]$Project,
    [switch]$Full,
    [switch]$DryRun,
    [string]$Target,
    [int]$Keep = -1,
    [switch]$NoHook,
    [string]$Config,
    [string]$LogFile
)

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $toolRoot 'lib\SyncKit.psm1') -Force

$code = 0
try {
    if ($LogFile) { Set-SyncLogFile -Path $LogFile }
    Write-Log -Message ('══ SyncKit {0} · 备份任务开始 @{1} ══' -f (Get-SyncKitVersion), (Get-SyncHostName)) -Level 'STEP'
    Write-Log -Message ('工具目录：{0}' -f $toolRoot) -Level 'INFO'

    $cfg = Get-SyncConfig -Path $Config
    $projects = @()
    if ($Project) { $projects = @(Get-SyncProject -Config $cfg -Id $Project) }
    else { $projects = @($cfg.projects) }

    if ($projects.Count -eq 0) {
        throw '没有已配置的项目。请运行 bin\start-gui.ps1 在界面里添加，或手工编辑 projects.json。'
    }

    $done = 0; $failed = 0; $skipped = 0
    foreach ($p in $projects) {
        if (-not $p.source) {
            Write-Log -Message ('跳过项目 [{0}]：未配置源目录（source）' -f $p.id) -Level 'WARN'
            $skipped++
            continue
        }
        Write-Log -Message ('── 项目：{0}（{1}）──' -f $p.name, $p.id) -Level 'STEP'
        try {
            $r = Invoke-SyncBackup -Config $cfg -Project $p -Full:$Full -DryRun:$DryRun `
                    -Target $Target -Keep $Keep -NoHook:$NoHook
            $done++
        }
        catch {
            Write-Log -Message ('项目 [{0}] 备份失败：{1}' -f $p.id, $_.Exception.Message) -Level 'ERROR'
            $failed++
        }
    }

    $verb = if ($DryRun) { '预览完成' } else { '任务结束' }
    if ($failed -gt 0) {
        Write-Log -Message ('{0}：成功 {1}，失败 {2}，跳过 {3}' -f $verb, $done, $failed, $skipped) -Level 'ERROR'
        $code = 1
    }
    else {
        Write-Log -Message ('{0}：成功 {1}，失败 0，跳过 {2}' -f $verb, $done, $skipped) -Level 'OK'
    }
}
catch {
    Write-Log -Message ('备份任务失败：{0}' -f $_.Exception.Message) -Level 'ERROR'
    $code = 1
}
finally {
    Write-JobExit -Code $code
}
exit $code
