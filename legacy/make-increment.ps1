#Requires -Version 5.1

<#
.SYNOPSIS
    电脑A端：把 storage 的变化打成包（全量 F-*.zip / 增量 I-*.zip），供拷贝到电脑B。

.DESCRIPTION
    同步模型（链式，全部使用同一种包格式，B端用同一个脚本应用）：

        F-xxx.zip（全量包，链头） ─ I-yyy.zip ─ I-zzz.zip ─ ...

      每个包内：
          files\<相对路径>   本包包含的文件（保留原修改时间）
          inc.meta           id / base（上一包ID，全量包为空）/ type（full|incremental）、
                            统计、每文件SHA256、删除清单

      生成规则：
        - 首次使用或需要重新对齐时：-Full 生成全量包（含全部文件）；
        - 之后日常运行：与 state\state.txt 记录的上次快照比对（大小 + 精确UTC修改时间），
          只打包新增/修改的文件，并在包内记录删除清单，秒级完成。

      状态文件 state\state.txt 由本脚本维护，记录最近一次生成的包ID与源目录完整
      文件清单，请勿手工修改；丢失后重新运行 -Full 生成新的全量包即可。

      复制失败的文件不计入本次清单，下次运行自动重试（与 backup-storage.ps1 策略一致）。

.PARAMETER Source
    Verdaccio 存储目录，默认为脚本上级目录的 data（.\..\data）。

.PARAMETER OutDir
    包输出目录，默认脚本同目录 increments。

.PARAMETER StateDir
    状态与日志目录，默认脚本同目录 state。

.PARAMETER Full
    生成全量包（含全部文件，新链起点）。首次使用、状态丢失、或想重新对齐时使用。

.PARAMETER Target
    可选：包生成后自动拷贝到的目标（U盘根目录如 E:\ 或网络共享 \\电脑B\share）。
    目标不存在时仅告警，包仍保留在 OutDir。

.PARAMETER Keep
    OutDir 中保留最近多少个包，更早的自动删除（默认 20，0 = 不清理）。

.PARAMETER PauseContainer
    打包前 docker pause verdaccio、结束后 docker unpause，保证快照一致性。

.EXAMPLE
    .\make-increment.ps1 -Full                 # 首次：生成全量包 F-*.zip
    .\make-increment.ps1                       # 日常：生成增量包 I-*.zip
    .\make-increment.ps1 -Target E:\           # 生成后自动拷到U盘（并带上B端脚本）
    .\make-increment.ps1 -PauseContainer       # 暂停容器保证一致性
#>

[CmdletBinding()]
param(
    # 默认值为相对脚本的路径，在脚本体开头的 Resolve-AnyPath 中统一解析
    # （不用 $PSScriptRoot 做默认值表达式：powershell -File 方式下该变量在参数绑定期为空）
    [string]$Source   = '..\data',
    [string]$OutDir   = 'increments',
    [string]$StateDir = 'state',
    [string]$Target,
    [ValidateRange(0, 1000)]
    [int]$Keep = 20,
    [switch]$Full,
    [switch]$PauseContainer
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$STATE_FILE = 'state.txt'
$META_ENTRY = 'inc.meta'
$FILES_ROOT = 'files/'        # zip 内文件条目前缀

$script:logLines = New-Object System.Collections.Generic.List[string]

function Write-Log {
    param([string]$Message)
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    $script:logLines.Add($line) | Out-Null
}

function Resolve-AnyPath([string]$P) {
    # 绝对路径原样规范化；相对路径相对脚本目录解析
    if ([IO.Path]::IsPathRooted($P)) { [IO.Path]::GetFullPath($P) }
    else { [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $P)) }
}

function Test-Nested([string]$A, [string]$B) {
    $a = ([IO.Path]::GetFullPath($A)).TrimEnd('\') + '\'
    $b = ([IO.Path]::GetFullPath($B)).TrimEnd('\') + '\'
    return $a.StartsWith($b, [StringComparison]::OrdinalIgnoreCase) -or
           $b.StartsWith($a, [StringComparison]::OrdinalIgnoreCase)
}

# 解析状态文件：id / base / created / [files] 大小|UTC ticks|相对路径
function Get-SyncState {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $st = @{ Id = ''; Base = ''; Created = ''; Files = @{} }
    $section = 'header'
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -eq '[files]') { $section = 'files'; continue }
        if ($section -eq 'header') {
            $i = $line.IndexOf('=')
            if ($i -gt 0) {
                $k = $line.Substring(0, $i)
                $v = $line.Substring($i + 1)
                switch ($k) {
                    'id'      { $st.Id = $v }
                    'base'    { $st.Base = $v }
                    'created' { $st.Created = $v }
                }
            }
        }
        elseif ($section -eq 'files') {
            if ($line) {
                $a = $line -split '\|', 3
                if ($a.Count -eq 3) { $st.Files[$a[2]] = @{ Size = [long]$a[0]; Ticks = [long]$a[1] } }
            }
        }
    }
    $st
}

try {
    # ---------------- 路径与前置检查 ----------------
    $Source   = Resolve-AnyPath $Source
    $OutDir   = Resolve-AnyPath $OutDir
    $StateDir = Resolve-AnyPath $StateDir

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw "源目录不存在：$Source" }
    if (Test-Nested $Source $OutDir)   { throw '输出目录与源目录不能互相嵌套。' }
    if (Test-Nested $Source $StateDir) { throw '状态目录与源目录不能互相嵌套。' }
    New-Item -ItemType Directory -Force -Path $OutDir, (Join-Path $StateDir 'logs') | Out-Null

    $logFile = Join-Path $StateDir ('logs\make-{0}-{1}.log' -f `
        (Get-Date -Format 'yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N').Substring(0, 4))

    if ($PauseContainer) {
        Write-Log 'docker pause verdaccio ...'
        docker pause verdaccio | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'docker pause 失败，中止。' }
    }

    # ---------------- 确定基线 ----------------
    $statePath = Join-Path $StateDir $STATE_FILE
    $state     = Get-SyncState -Path $statePath

    $basisExact = $false
    if ($Full) {
        $basisExact = $false
        $basisId    = ''
        Write-Log '本次为全量包（-Full）：包含全部文件，作为新链起点。'
    }
    elseif ($state -and $state.Id) {
        $basisExact = $true
        $basisId    = $state.Id
        Write-Log ("以上次快照为基线：{0}（{1}），清单文件 {2} 个" -f `
            $basisId, $state.Created, $state.Files.Count)
    }
    else {
        throw "没有同步状态。首次使用或状态丢失时，请先运行：.\make-increment.ps1 -Full 生成全量包。"
    }

    # ---------------- 枚举源目录 ----------------
    $srcIndex = @{}
    Get-ChildItem -LiteralPath $Source -Recurse -File -Force |
        Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
        ForEach-Object { $srcIndex[$_.FullName.Substring($Source.Length + 1)] = $_ }
    Write-Log "源目录文件总数：$($srcIndex.Count)"

    # ---------------- 差异比较 ----------------
    $changed = New-Object System.Collections.Generic.List[string]
    $n = 0
    foreach ($rel in @($srcIndex.Keys)) {
        $n++
        if ($basisExact) {
            $f = $srcIndex[$rel]
            $b = $state.Files[$rel]
            if ($b -and $b.Size -eq $f.Length -and $b.Ticks -eq $f.LastWriteTimeUtc.Ticks) { continue }
        }
        $changed.Add($rel)
        if ($n % 500 -eq 0) {
            Write-Progress -Activity '差异比较' -Status "已比较 $n / $($srcIndex.Count)，变化 $($changed.Count)"
        }
    }
    Write-Progress -Activity '差异比较' -Completed

    $deleted = New-Object System.Collections.Generic.List[string]
    if ($basisExact) {
        foreach ($rel in @($state.Files.Keys)) {
            if (-not $srcIndex.ContainsKey($rel)) { $deleted.Add($rel) }
        }
    }
    Write-Log ("差异：新增/修改 {0} 个，删除 {1} 个" -f $changed.Count, $deleted.Count)

    # ---------------- 生成包 ----------------
    $prefix = if ($Full) { 'F-' } else { 'I-' }
    $newId   = $prefix + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 4)
    $zipPath = $null
    $failed  = @{}

    if ($changed.Count -eq 0 -and $deleted.Count -eq 0) {
        Write-Log '无任何变化，未生成增量包。'
    }
    else {
        $tmpZip = Join-Path $OutDir ('.' + $newId + '.tmp')
        $zip = New-Object IO.Compression.ZipArchive(
            ([IO.File]::Open($tmpZip, [IO.FileMode]::CreateNew)),
            [IO.Compression.ZipArchiveMode]::Create, $false, [Text.Encoding]::UTF8)
        $packed = 0
        $metaLines = New-Object System.Collections.Generic.List[string]
        try {
            foreach ($rel in $changed) {
                $f = $srcIndex[$rel]
                try {
                    $sha = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
                    $entry = $zip.CreateEntry($FILES_ROOT + ($rel -replace '\\', '/'))
                    $entry.LastWriteTime = $f.LastWriteTime
                    $in = [IO.File]::OpenRead($f.FullName)
                    $out = $entry.Open()
                    try { $in.CopyTo($out) } finally { $in.Dispose(); $out.Dispose() }
                    $metaLines.Add(('{0}|{1}|{2}' -f $sha, $f.Length, $rel))
                    $packed++
                }
                catch {
                    $failed[$rel] = $_.Exception.Message
                    Write-Log "打包失败（下次自动重试）：$rel -- $($_.Exception.Message)"
                }
            }

            $meta = New-Object System.Collections.Generic.List[string]
            $meta.Add("id=$newId")
            $meta.Add("base=$basisId")
            $meta.Add("type=$(if ($Full) { 'full' } else { 'incremental' })")
            $meta.Add("created=$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))")
            $meta.Add("fileTotal=$($srcIndex.Count)")
            $meta.Add("copied=$packed")
            $meta.Add("deleted=$($deleted.Count)")
            $meta.Add("failed=$($failed.Count)")
            $meta.Add('[files]')
            foreach ($l in $metaLines) { $meta.Add($l) }
            $meta.Add('[deleted]')
            foreach ($rel in $deleted) { $meta.Add($rel) }

            $mEntry = $zip.CreateEntry($META_ENTRY)
            $sw = New-Object IO.StreamWriter($mEntry.Open(), (New-Object Text.UTF8Encoding($false)))
            try { $sw.Write(($meta -join "`r`n")) } finally { $sw.Dispose() }
        }
        finally { $zip.Dispose() }

        Rename-Item -LiteralPath $tmpZip -NewName ($newId + '.zip')
        $zipPath = Join-Path $OutDir ($newId + '.zip')

        # 自检：重开 zip 确认条目数一致
        $chk = New-Object IO.Compression.ZipArchive(([IO.File]::OpenRead($zipPath)), [IO.Compression.ZipArchiveMode]::Read)
        try { $entryCount = @($chk.Entries | Where-Object { $_.FullName.StartsWith($FILES_ROOT) }).Count }
        finally { $chk.Dispose() }
        if ($entryCount -ne $packed) { throw "自检失败：zip 内文件条目 $entryCount != 打包数 $packed" }

        $sizeMB = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 1)
        $kindName = if ($Full) { '全量包' } else { '增量包' }
        Write-Log ("{0}已生成：{1}.zip（{2} MB，{3} 个文件，记录删除 {4}）" -f $kindName, $newId, $sizeMB, $packed, $deleted.Count)
    }

    # ---------------- 更新状态文件（排除失败文件，便于下次重试） ----------------
    $stLines = New-Object System.Collections.Generic.List[string]
    $stLines.Add("id=$(if ($zipPath) { $newId } else { $state.Id })")
    $stLines.Add("base=$basisId")
    $stLines.Add("created=$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))")
    $stLines.Add('[files]')
    foreach ($rel in @($srcIndex.Keys | Where-Object { -not $failed.ContainsKey($_) } | Sort-Object)) {
        $f = $srcIndex[$rel]
        $stLines.Add(('{0}|{1}|{2}' -f $f.Length, $f.LastWriteTimeUtc.Ticks, $rel))
    }
    [IO.File]::WriteAllLines($statePath, $stLines, (New-Object System.Text.UTF8Encoding($true)))
    Write-Log "状态文件已更新：$statePath"

    # ---------------- 清理旧包 ----------------
    if ($Keep -gt 0) {
        $old = @()
        foreach ($pat in @('I-*.zip', 'F-*.zip')) {
            $old += @(Get-ChildItem -LiteralPath $OutDir -File -Filter $pat)
        }
        $old = @($old | Sort-Object Name -Descending)
        if ($old.Count -gt $Keep) {
            foreach ($z in ($old | Select-Object -Skip $Keep)) {
                Write-Log "清理旧包：$($z.Name)"
                Remove-Item -LiteralPath $z.FullName -Force
            }
        }
    }

    # ---------------- 拷贝到目标（U盘/共享） ----------------
    if ($Target) {
        $Target = [IO.Path]::GetFullPath($Target)
        if (Test-Path -LiteralPath $Target -PathType Container) {
            if ($zipPath) {
                Copy-Item -LiteralPath $zipPath -Destination (Join-Path $Target (Split-Path -Leaf $zipPath)) -Force
                Write-Log "包已拷贝到：$Target"
            }
            # 首次使用时把B端工具一并带上
            foreach ($tool in @('apply-increment.ps1', 'README-增量同步到电脑B.md')) {
                $srcTool = Join-Path $PSScriptRoot $tool
                if ((Test-Path -LiteralPath $srcTool) -and -not (Test-Path -LiteralPath (Join-Path $Target $tool))) {
                    Copy-Item -LiteralPath $srcTool -Destination $Target -Force
                    Write-Log "已向目标提供B端工具：$tool"
                }
            }
            Write-Host "请将 $Target 中的包带到电脑B，放入其 increments 目录后运行 apply-increment.ps1。" -ForegroundColor Cyan
        }
        else {
            Write-Warning "目标不可用（未拷贝）：$Target ；包仍保存在 $OutDir"
        }
    }
    elseif ($zipPath) {
        Write-Host "下一步：把 $zipPath 拷贝到电脑B的 increments 目录，运行 apply-increment.ps1。" -ForegroundColor Cyan
    }

    if ($failed.Count -gt 0) {
        Write-Host "完成，但 $($failed.Count) 个文件打包失败（下次运行自动重试），详见 $logFile" -ForegroundColor Yellow
        exit 1
    }
    Write-Host '完成。' -ForegroundColor Green
    exit 0
}
catch {
    Write-Log "失败：$($_.Exception.Message)"
    throw
}
finally {
    if ($PauseContainer) {
        docker unpause verdaccio | Out-Null
        Write-Log 'docker unpause verdaccio（容器已恢复运行）'
    }
    if ($logFile) { $script:logLines | Set-Content -LiteralPath $logFile -Encoding UTF8 }
}
