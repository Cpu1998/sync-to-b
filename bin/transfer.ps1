#Requires -Version 5.1
<#
.SYNOPSIS
    SyncKit 转移工具：把备份包打成「转移包」带到另一台机器，或把转移包导入本机。

.DESCRIPTION
    转移包是一个自包含的 zip（或目录）：
        sync-<项目>-<时间>.zip
        ├── 说明.txt            步骤说明（含每个包的 SHA256）
        ├── bundle.json         包清单与来源信息
        ├── sha256.txt          转移包内全部文件的 SHA256
        ├── restore.bat         目标机双击即可还原
        ├── packages\           备份包本体（F-*.zip / I-*.zip）
        └── sync-tool\          精简版还原工具 + 预填好的 projects.json

    目标机不需要预装本工具：解压 → 改一下 sync-tool\projects.json 里的 target →
    双击 restore.bat。之后每次把新转移包解压到同一个目录覆盖，再双击一次即可（进度累积）。

    默认只导出「尚未导出过的包」（-Include new），这样日常转移量很小；
    需要完整搬家时用 -Include all。

.PARAMETER Action
    export = 生成转移包；import = 把转移包导入本机项目的收件箱；list = 查看导出记录。

.PARAMETER Project
    项目 ID。export 省略 = 所有有包的项目；import 省略 = 用转移包里的项目 ID。

.PARAMETER Dest
    转移包输出位置：目录、U 盘盘符（E:\）、网络共享（\\主机\共享）。

.PARAMETER Include
    new（默认）只导出新包；all 导出全部现存包。

.PARAMETER Format
    zip（默认，单文件，便于拷贝）或 folder（目录，可直接在里面跑）。

.PARAMETER SplitMB
    大于 0 时把 zip 切成多个分卷（例如 U 盘 4GB 限制时用 3500）。
    目标机先运行同目录的 join-parts.bat 合并回 zip。

.PARAMETER Bundle
    import 时指定转移包路径（zip 或已解压的目录）。

.PARAMETER Apply
    import 后立刻应用（否则只入收件箱，等你在界面里确认）。

.EXAMPLE
    .\bin\transfer.ps1 -Action export -Project drive-backup -Dest E:\
    .\bin\transfer.ps1 -Action export -Project drive-backup -Dest D:\搬家 -Include all -SplitMB 3500
    .\bin\transfer.ps1 -Action import -Bundle E:\sync-drive-backup-20260928-170000.zip -Apply
    .\bin\transfer.ps1 -Action list -Project drive-backup
#>
[CmdletBinding()]
param(
    [ValidateSet('export', 'import', 'list')][string]$Action = 'export',
    [string]$Project,
    [string]$Dest,
    [ValidateSet('new', 'all')][string]$Include = 'new',
    [ValidateSet('zip', 'folder')][string]$Format = 'zip',
    [int]$SplitMB = 0,
    [string]$Bundle,
    [switch]$Apply,
    [string]$Config,
    [string]$LogFile
)

$ErrorActionPreference = 'Stop'
$toolRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $toolRoot 'lib\SyncKit.psm1') -Force

$code = 0
try {
    if ($LogFile) { Set-SyncLogFile -Path $LogFile }
    $cfg = Get-SyncConfig -Path $Config

    switch ($Action) {

        'export' {
            Write-Log -Message ('══ SyncKit {0} · 导出转移包 ══' -f (Get-SyncKitVersion)) -Level 'STEP'
            if (-not $Dest) { $Dest = Join-Path $toolRoot 'transfer-out' }
            Write-Log -Message ('输出位置：{0}' -f $Dest) -Level 'INFO'
            if ($SplitMB -gt 0 -and $Format -ne 'zip') {
                Write-Log -Message '分卷只对 zip 有效，已忽略 -SplitMB。' -Level 'WARN'
                $SplitMB = 0
            }

            $projects = @()
            if ($Project) { $projects = @(Get-SyncProject -Config $cfg -Id $Project) }
            else { $projects = @($cfg.projects) }
            if ($projects.Count -eq 0) { throw '没有已配置的项目。' }

            $made = 0; $failed = 0
            foreach ($p in $projects) {
                Write-Log -Message ('── 项目：{0}（{1}）──' -f $p.name, $p.id) -Level 'STEP'
                try {
                    $r = New-TransferBundle -Config $cfg -Project $p -Dest $Dest -Include $Include -Format $Format -SplitMB $SplitMB
                    if ($r) {
                        $made++
                        $shown = if ($r -is [array]) { ($r | Select-Object -First 1) } else { $r }
                        Write-Log -Message ('完成：{0}' -f $shown) -Level 'OK'
                    }
                }
                catch {
                    Write-Log -Message ('项目 [{0}] 导出失败：{1}' -f $p.id, $_.Exception.Message) -Level 'ERROR'
                    $failed++
                }
            }
            if ($failed -gt 0) { $code = 1 }
            else { Write-Log -Message ('导出完成，共 {0} 个项目。' -f $made) -Level 'OK' }
        }

        'import' {
            Write-Log -Message ('══ SyncKit {0} · 导入转移包 ══' -f (Get-SyncKitVersion)) -Level 'STEP'
            if (-not $Bundle) { throw '请用 -Bundle 指定转移包路径（zip 或目录）。' }
            $code = [int](Import-TransferBundle -Config $cfg -BundlePath $Bundle -ProjectId $Project -NoApply:(-not $Apply))
            if ($code -eq 0) { Write-Log -Message '导入完成。' -Level 'OK' }
        }

        'list' {
            Write-Log -Message ('══ SyncKit {0} · 导出 / 导入记录 ══' -f (Get-SyncKitVersion)) -Level 'STEP'
            $projects = @()
            if ($Project) { $projects = @(Get-SyncProject -Config $cfg -Id $Project) }
            else { $projects = @($cfg.projects) }
            foreach ($p in $projects) {
                $Paths = Get-ProjectPaths -Config $cfg -Project $p
                $recs = @(Get-Exports -Path $Paths.ExportsFile)
                Write-Log -Message ('── {0}（{1}）：{2} 条记录' -f $p.name, $p.id, $recs.Count) -Level 'INFO'
                foreach ($r in ($recs | Select-Object -Last 15)) {
                    Write-Log -Message ('  {0}  [{1}]  {2}  包 {3} 个' -f $r.at, $r.format, $r.dest, @($r.packages).Count) -Level 'INFO'
                }
            }
        }
    }
}
catch {
    Write-Log -Message ('转移任务失败：{0}' -f $_.Exception.Message) -Level 'ERROR'
    $code = 1
}
finally {
    Write-JobExit -Code $code
}
exit $code
