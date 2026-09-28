#Requires -Version 5.1

<#
.SYNOPSIS
    电脑B端：把 increments\ 中待应用的包（全量 F-*.zip / 增量 I-*.zip）按链序应用到本地存储目录
    （默认为脚本上级目录的 data，与A端对称）。

.DESCRIPTION
    与A端 make-increment.ps1 配套使用。数据模型（同一格式，链式）：

        F-xxx.zip（全量包，链头，含全部文件） ─ I-yyy.zip ─ I-zzz.zip ─ ...

      首次使用（一次性）：把A端生成的【全量包 F-*.zip】（及之后的增量包）放入
      .\increments\ ，运行本脚本即可——不需要单独解压任何 zip、没有特殊基线文件。

      日常使用：把从A端拷来的 I-*.zip 放入 .\increments\ ，运行本脚本。

      脚本自动按 base 链找到"接得上"的包，逐个：
        1. 解压到临时目录；
        2. 逐文件核对 SHA256（防U盘拷贝损坏），全部通过才落地；
        3. 覆盖/新增文件、执行删除清单（并清理变空的目录）；
           全量包（type=full）额外做镜像清理：删除 data 中不在其清单内的文件，
           保证应用后与该全量包完全一致（可安全重复应用）；
        4. 应用成功的包移入 .\increments\applied\ ，进度写入 .sync-state.json。
        中途失败时该包留在原地，直接重跑即可（应用操作可安全重复）。

      安全机制：
        - 链校验：增量包的 base 必须等于B端当前状态（缺少中间包/乱序会明确报错）；
          从零开始必须先有全量包 F-*.zip；
        - 重新对齐：现链接不上时，可用【比当前状态新的全量包】直接对齐
          （全量包自包含全部文件，且应用时镜像清理，落在任何旧状态上都安全）；
        - 校验失败不落地：先整包校验后写入，避免半新半旧；
        - 若B端也在运行 verdaccio 容器，请先 docker stop verdaccio 再应用。

.PARAMETER DataDir
    数据目录，默认脚本上级目录的 data（与A端 make-increment.ps1 的 -Source 默认值对称）。

.PARAMETER Inbox
    待应用包目录，默认脚本同目录 increments。

.PARAMETER Plan
    只显示将要应用的包链与无法连接的包，不做任何改动。

.EXAMPLE
    .\apply-increment.ps1          # 首次/日常：应用 increments\ 中的包
    .\apply-increment.ps1 -Plan    # 预览
#>

[CmdletBinding()]
param(
    # 默认值为相对脚本的路径，在脚本体开头的 Resolve-AnyPath 中统一解析
    # （不用 $PSScriptRoot 做默认值表达式：powershell -File 方式下该变量在参数绑定期为空）
    [string]$DataDir = '..\data',
    [string]$Inbox   = 'increments',
    [switch]$Plan
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$STATE_FILE = '.sync-state.json'
$META_ENTRY = 'inc.meta'
$FILES_ROOT = 'files/'

$script:logLines = New-Object System.Collections.Generic.List[string]

function Write-Log {
    param([string]$Message)
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    $script:logLines.Add($line) | Out-Null
}

function Resolve-AnyPath([string]$P) {
    if ([IO.Path]::IsPathRooted($P)) { [IO.Path]::GetFullPath($P) }
    else { [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $P)) }
}

function Test-Nested([string]$A, [string]$B) {
    $a = ([IO.Path]::GetFullPath($A)).TrimEnd('\') + '\'
    $b = ([IO.Path]::GetFullPath($B)).TrimEnd('\') + '\'
    return $a.StartsWith($b, [StringComparison]::OrdinalIgnoreCase) -or
           $b.StartsWith($a, [StringComparison]::OrdinalIgnoreCase)
}

function Open-Zip([string]$Path) {
    New-Object IO.Compression.ZipArchive(
        ([IO.File]::OpenRead($Path)), [IO.Compression.ZipArchiveMode]::Read, $false, [Text.Encoding]::UTF8)
}

# 解析包内 inc.meta：
# 返回 @{ Id;Base;Type;Created;Files=@(rel -> @{Sha;Size})（保持顺序）;Deleted=@() }
function Get-IncMeta {
    param([Parameter(Mandatory)][string]$ZipPath)
    $zip = Open-Zip $ZipPath
    try {
        $mEntry = $zip.GetEntry($META_ENTRY)
        if (-not $mEntry) { throw "缺少 $META_ENTRY，不是本方案的包：$ZipPath" }
        $sr = New-Object IO.StreamReader($mEntry.Open(), [Text.Encoding]::UTF8)
        try { $text = $sr.ReadToEnd() } finally { $sr.Dispose() }

        $meta = @{ ZipPath = $ZipPath; Files = @(); Deleted = @() }
        $section = 'header'
        foreach ($line in ($text -split "`r?`n")) {
            if ($line -eq '[files]')   { $section = 'files';   continue }
            if ($line -eq '[deleted]') { $section = 'deleted'; continue }
            if ($section -eq 'header') {
                $i = $line.IndexOf('=')
                if ($i -gt 0) {
                    switch ($line.Substring(0, $i)) {
                        'id'      { $meta.Id = $line.Substring($i + 1) }
                        'base'    { $meta.Base = $line.Substring($i + 1) }
                        'type'    { $meta.Type = $line.Substring($i + 1) }
                        'created' { $meta.Created = $line.Substring($i + 1) }
                    }
                }
            }
            elseif ($section -eq 'files') {
                if ($line) {
                    $a = $line -split '\|', 3
                    if ($a.Count -eq 3) {
                        $meta.Files += @{ Rel = $a[2]; Sha = $a[0]; Size = [long]$a[1] }
                    }
                }
            }
            elseif ($line) { $meta.Deleted += $line }
        }
        if (-not $meta.Id) { throw "inc.meta 缺少 id：$ZipPath" }
        $meta
    }
    finally { $zip.Dispose() }
}

function Save-State {
    param([hashtable]$State)
    $State.updatedAt = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
    $State | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $PSScriptRoot $STATE_FILE) -Encoding UTF8
}

# 删除文件及其变空的父目录（不越过 DataDir）
function Remove-FileAndEmptyParents {
    param([Parameter(Mandatory)][string]$DataDir, [Parameter(Mandatory)][string]$RelPath)
    $p = Join-Path $DataDir $RelPath
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    $parent = Split-Path -Parent $p
    while ($parent -and $parent.Length -gt $DataDir.Length -and
           $parent.StartsWith($DataDir, [StringComparison]::OrdinalIgnoreCase)) {
        if (@(@(Get-ChildItem -LiteralPath $parent -Force)).Count -gt 0) { break }
        Remove-Item -LiteralPath $parent -Force
        $parent = Split-Path -Parent $parent
    }
}

# 包 ID 形如 F-20260928-102019-be67：第 3 字符起是 yyyyMMdd-HHmmss，可按此比较包新旧
function Get-IdTimestamp([string]$Id) {
    if ($Id -and $Id.Length -ge 17) { $Id.Substring(2, 15) } else { '' }
}

try {
    $DataDir = Resolve-AnyPath $DataDir
    $Inbox   = Resolve-AnyPath $Inbox
    if (Test-Nested $DataDir $Inbox) { throw '数据目录与收件箱目录不能互相嵌套。' }
    $statePath = Join-Path $PSScriptRoot $STATE_FILE

    # ---------------- 读取进度 ----------------
    $state = $null
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    if (-not $state) {
        $state = @{ lastId = ''; applied = @() }
        if (Test-Path -LiteralPath $DataDir -PathType Container) {
            $n = @(Get-ChildItem -LiteralPath $DataDir -Recurse -File -Force).Count
            if ($n -gt 0) {
                Write-Warning "data 目录已有 $n 个文件但没有进度记录：请放入全量包 F-*.zip 重新对齐（应用时会镜像清理多余文件）。"
            }
        }
    }
    elseif ([string]$state.lastId -ne '') {
        # 反向情况：有进度记录但 data 一个文件都没有——多半是误拷了别处的 .sync-state.json
        $n = 0
        if (Test-Path -LiteralPath $DataDir -PathType Container) {
            $n = @(Get-ChildItem -LiteralPath $DataDir -Recurse -File -Force).Count
        }
        if ($n -eq 0) {
            Write-Warning "进度记录显示已应用到 $($state.lastId)，但 data 目录没有任何文件：若是误拷了别处的进度文件，删除 $statePath 后重跑即可。"
        }
    }

    if (-not (Test-Path -LiteralPath $Inbox -PathType Container)) {
        Write-Host "没有待应用的包（目录不存在：$Inbox）。"
        exit 0
    }

    # ---------------- 读取收件箱内全部包 ----------------
    $metas = @{}
    foreach ($pat in @('I-*.zip', 'F-*.zip')) {
        foreach ($z in @(Get-ChildItem -LiteralPath $Inbox -File -Filter $pat)) {
            try {
                $m = Get-IncMeta -ZipPath $z.FullName
                $metas[$m.Id] = $m
            }
            catch {
                Write-Warning "跳过无法读取的包（$($z.Name)）：$($_.Exception.Message)"
            }
        }
    }
    if ($metas.Count -eq 0) {
        Write-Host "没有待应用的包：$Inbox"
        exit 0
    }

    # ---------------- 沿 base 链确定应用顺序 ----------------
    $pointer = [string]$state.lastId
    $chain = New-Object System.Collections.Generic.List[object]
    $chained = @{}
    $realigned = $false
    while ($true) {
        if ($pointer -eq '') {
            # 链头必须是全量包
            $cand = @($metas.Values | Where-Object {
                (-not $chained.ContainsKey($_.Id)) -and ($_.Type -eq 'full')
            })
        }
        else {
            $cand = @($metas.Values | Where-Object {
                (-not $chained.ContainsKey($_.Id)) -and ($_.Base -eq $pointer)
            })
            # 现链接不上时，用【更新的全量包】重新对齐（-Full 新链即走这条路）：
            # 全量包自包含全部文件且应用时做镜像清理，落在任何旧状态上都安全；
            # 只取比当前状态新的最新一个，且至多对齐一次，防止旧全量包把数据倒回去。
            if ($cand.Count -eq 0 -and -not $realigned) {
                $nowTs = Get-IdTimestamp $pointer
                $cand = @($metas.Values | Where-Object {
                    (-not $chained.ContainsKey($_.Id)) -and ($_.Type -eq 'full') -and
                    ((Get-IdTimestamp $_.Id) -gt $nowTs)
                } | Sort-Object Id -Descending | Select-Object -First 1)
                if ($cand.Count -gt 0) {
                    $realigned = $true
                    Write-Host ("当前状态 {0} 后续没有增量包，改用更新的全量包重新对齐：{1}" -f `
                        $pointer, $cand[0].Id) -ForegroundColor Yellow
                }
            }
        }
        if ($cand.Count -eq 0) { break }
        if ($cand.Count -gt 1) {
            $ids = ($cand | ForEach-Object { $_.Id }) -join ', '
            Write-Warning "同一位置有多个包（$ids），按 ID 取最新。"
            $cand = @($cand | Sort-Object Id -Descending)
        }
        $c = $cand[0]
        $chain.Add($c)
        $chained[$c.Id] = $true
        $pointer = $c.Id
    }
    foreach ($m in $metas.Values) {
        if (-not $chained.ContainsKey($m.Id)) {
            if ([string]$state.lastId -eq '') {
                Write-Warning ("无法接入当前状态的包：{0}.zip -- 当前没有进度，链头必须是全量包（type=full 的 F-*.zip）" -f $m.Id)
            }
            elseif ($m.Type -eq 'full') {
                Write-Warning ("跳过全量包：{0}.zip -- 不比当前状态（{1}）新，或已有更新的全量包被应用" -f $m.Id, $pointer)
            }
            else {
                Write-Warning ("无法接入当前状态的包：{0}.zip（其 base={1}，当前状态={2}）-- 可能缺少中间包或尚未带过来" -f `
                    $m.Id, $m.Base, $pointer)
            }
        }
    }

    if ($chain.Count -eq 0) {
        Write-Host '没有可应用的包（见上方警告）。'
        exit 1
    }

    Write-Host ("将按序应用 {0} 个包：{1}" -f $chain.Count, (($chain | ForEach-Object { $_.Id }) -join '  ->  '))
    if ($Plan) {
        Write-Host '-Plan：仅预览，未做任何改动。'
        exit 0
    }

    # ---------------- 逐包应用 ----------------
    $appliedDir = Join-Path $Inbox 'applied'
    New-Item -ItemType Directory -Force -Path $appliedDir, $DataDir | Out-Null
    $appliedList = @($state.applied)
    $copiedTotal = 0; $deletedTotal = 0

    foreach ($m in $chain) {
        $kindName = if ($m.Type -eq 'full') { '全量包' } else { '增量包' }
        Write-Host "`n=== 应用$kindName $($m.Id)（$(if ($m.Created) { $m.Created } else { '时间未知' })，$($m.Files.Count) 个文件，删除 $($m.Deleted.Count)）===" -ForegroundColor Cyan
        $tmp = Join-Path $env:TEMP ('inc-apply-' + $m.Id)
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
        try {
            # 1) 先整包解压到临时目录
            $zip = Open-Zip $m.ZipPath
            try {
                foreach ($e in $zip.Entries) {
                    if (-not $e.FullName.StartsWith($FILES_ROOT) -or $e.FullName.EndsWith('/')) { continue }
                    $rel = ($e.FullName.Substring($FILES_ROOT.Length)) -replace '/', '\'
                    $dst = Join-Path $tmp $rel
                    $parent = Split-Path -Parent $dst
                    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                        New-Item -ItemType Directory -Force -Path $parent | Out-Null
                    }
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dst, $true)
                }
            }
            finally { $zip.Dispose() }

            # 2) 逐文件校验 SHA256，全部通过才落地
            foreach ($f in $m.Files) {
                $p = Join-Path $tmp $f.Rel
                if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "包内缺少文件：$($f.Rel)" }
                $actual = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash
                if ($actual -ne $f.Sha) { throw "SHA256 校验失败：$($f.Rel)（包可能拷贝损坏，请重新拷贝该 zip）" }
            }
            Write-Host "  校验通过：$($m.Files.Count) 个文件 SHA256 全部一致。"

            # 3) 落地：覆盖/新增
            foreach ($f in $m.Files) {
                $src = Join-Path $tmp $f.Rel
                $dst = Join-Path $DataDir $f.Rel
                $parent = Split-Path -Parent $dst
                if ($parent -and -not (Test-Path -LiteralPath $parent)) {
                    New-Item -ItemType Directory -Force -Path $parent | Out-Null
                }
                Copy-Item -LiteralPath $src -Destination $dst -Force
                $copiedTotal++
            }

            # 4) 删除清单
            foreach ($rel in $m.Deleted) {
                if (Test-Path -LiteralPath (Join-Path $DataDir $rel)) {
                    Write-Host "  已删除：$rel"
                }
                Remove-FileAndEmptyParents -DataDir $DataDir -RelPath $rel
                $deletedTotal++
            }

            # 5) 全量包：镜像清理（删除不在清单内的文件，保证与全量包完全一致）
            if ($m.Type -eq 'full') {
                $inventory = @{}
                foreach ($f in $m.Files) { $inventory[$f.Rel] = $true }
                $extra = @(Get-ChildItem -LiteralPath $DataDir -Recurse -File -Force |
                    Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
                    ForEach-Object { $_.FullName.Substring($DataDir.Length + 1) } |
                    Where-Object { -not $inventory.ContainsKey($_) })
                foreach ($rel in $extra) {
                    Remove-FileAndEmptyParents -DataDir $DataDir -RelPath $rel
                    $deletedTotal++
                }
                if ($extra.Count -gt 0) {
                    Write-Host "  镜像清理：删除不在全量包清单内的文件 $($extra.Count) 个"
                }
            }
        }
        finally {
            if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
        }

        # 6) 包移入 applied，进度落盘（之后重跑不会重复应用）
        Move-Item -LiteralPath $m.ZipPath -Destination (Join-Path $appliedDir (Split-Path -Leaf $m.ZipPath)) -Force
        $appliedList = @($appliedList) + $m.Id
        Save-State @{ lastId = $m.Id; applied = $appliedList }
        Write-Host "  完成，包已移入 $appliedDir" -ForegroundColor Green
    }

    $fileCount = @(Get-ChildItem -LiteralPath $DataDir -Recurse -File -Force).Count
    Write-Host ("`n全部完成：应用 {0} 个包，落地 {1} 个文件，删除 {2} 个；data 现有 {3} 个文件。" -f `
        $chain.Count, $copiedTotal, $deletedTotal, $fileCount) -ForegroundColor Green
    Write-Host "当前状态：已应用到 $pointer。"
    exit 0
}
catch {
    Write-Host "应用失败：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host '该包仍保留在原地；排查后直接重新运行本脚本即可（应用操作可安全重复）。'
    exit 1
}
