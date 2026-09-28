#Requires -Version 5.1
<#
    SyncKit —— 通用「增量备份 / 跨机转移」核心模块

    设计目标：与任何具体业务无关。任何目录都可以作为一个「项目」纳入管理，
    一台机器上可以同时管理多个项目，也可以同时扮演「打包端」和「还原端」。

    数据模型（链式，包格式统一，还原端只有一个脚本）：

        F-xxx.zip（全量包，链头，含全部文件） ─ I-yyy.zip ─ I-zzz.zip ─ ...

        包内：
            files\<相对路径>   本包包含的文件（保留原修改时间）
            inc.meta           文本清单：id / base / type / project / 每文件 SHA256 / 删除清单

    核心特性（沿用并强化原 verdaccio 方案的可靠机制）：
        · 链校验    —— 增量包的 base 必须等于当前状态；缺包/乱序会明确报出，绝不应用错
        · 重新对齐  —— 现链接不上时可用「更新的全量包」直接对齐（全量包做镜像清理，落在任何旧状态都安全）
        · 先校验后落地 —— 整包解压到临时目录、逐文件 SHA256 全部通过才写入，防拷贝损坏造成半新半旧
        · 删除同步  —— 源端删除的文件记录在包的 [deleted] 清单，还原端一并删除并清理空目录
        · 失败可重入 —— 打包失败的文件不计入清单，下次自动重试；应用操作可安全重复

    模块目录约定：
        <工具根>\  projects.json        多项目配置
                   bin\ 、lib\ 、web\
                   data\               运行数据（每个项目一份 state / increments / logs）
#>

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

$script:SyncKitVersion = '2.0.0'
$script:META_ENTRY     = 'inc.meta'
$script:FILES_ROOT     = 'files/'
$script:STATE_FILE     = 'state.txt'
$script:APPLIED_FILE   = 'applied.json'
$script:EXPORTS_FILE   = 'exports.json'
$script:LogFile        = ''
$script:Utf8NoBom      = New-Object System.Text.UTF8Encoding($false)

#region ───────────────────────── 基础工具 ─────────────────────────

function Get-SyncToolRoot {
    <# 工具根目录（lib 的上一级）。整个工具可以整体拷贝到任意位置使用。#>
    [CmdletBinding()] param()
    Split-Path -Parent $PSScriptRoot
}

function Get-SyncKitVersion { [CmdletBinding()] param() $script:SyncKitVersion }

function Get-SyncHostName {
    <# 某些精简环境下 COMPUTERNAME 为空，退回 .NET 的机器名。#>
    [CmdletBinding()] param()
    if ($env:COMPUTERNAME) { return $env:COMPUTERNAME }
    try { return [Environment]::MachineName } catch { return 'unknown' }
}

function Write-Log {
    <#
      统一日志：同时输出到控制台与日志文件（供 GUI 实时读取）。
      级别前缀 [INFO]/[WARN]/[ERROR]/[OK]/[STEP] 会被界面着色。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, Mandatory = $true)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'STEP')][string]$Level = 'INFO',
        [string]$LogFile
    )
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line  = '{0} [{1}] {2}' -f $stamp, $Level, $Message

    $color = 'Gray'
    switch ($Level) {
        'WARN'  { $color = 'Yellow' }
        'ERROR' { $color = 'Red' }
        'OK'    { $color = 'Green' }
        'STEP'  { $color = 'Cyan' }
    }
    Write-Host $line -ForegroundColor $color

    $target = $LogFile
    if (-not $target) { $target = $script:LogFile }
    if ($target) {
        try {
            $dir = Split-Path -Parent $target
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            [IO.File]::AppendAllText($target, $line + "`r`n", $script:Utf8NoBom)
        }
        catch { }
    }
}

function Set-SyncLogFile {
    <# 设定全程默认日志文件（GUI 任务会用到）。#>
    [CmdletBinding()] param([string]$Path)
    $script:LogFile = $Path
    if ($Path) {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        if (-not (Test-Path -LiteralPath $Path)) { [IO.File]::WriteAllText($Path, '', $script:Utf8NoBom) }
    }
}

function Write-JobExit {
    <# 任务结束标记：界面靠这一行判断子进程的成败。#>
    [CmdletBinding()] param([int]$Code = 0)
    Write-Log -Message ('[EXIT] {0}' -f $Code) -Level 'INFO'
}

function Resolve-AnyPath {
    <# 展开环境变量；相对路径按 $Base（默认工具根）解析。#>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowEmptyString()][string]$Path,
        [string]$Base
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if (-not $Base) { $Base = Get-SyncToolRoot }
    $p = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    if ([IO.Path]::IsPathRooted($p)) { return [IO.Path]::GetFullPath($p) }
    [IO.Path]::GetFullPath((Join-Path $Base $p))
}

function Test-NestedPath {
    <# 两个路径是否互相嵌套（相同也算）。用于防止「备份产物落到被备份的目录里」。#>
    [CmdletBinding()] param([string]$A, [string]$B)
    if (-not $A -or -not $B) { return $false }
    $a = ([IO.Path]::GetFullPath($A)).TrimEnd('\') + '\'
    $b = ([IO.Path]::GetFullPath($B)).TrimEnd('\') + '\'
    return ($a.StartsWith($b, [StringComparison]::OrdinalIgnoreCase) -or
            $b.StartsWith($a, [StringComparison]::OrdinalIgnoreCase))
}

function Test-IsReparsePoint {
    [CmdletBinding()] param([Parameter(Mandatory)]$Item)
    return [bool]($Item.Attributes -band [IO.FileAttributes]::ReparsePoint)
}

function Get-FreeSpace {
    [CmdletBinding()] param([string]$Path)
    try {
        $full = [IO.Path]::GetFullPath($Path)
        $root = [IO.Path]::GetPathRoot($full)
        $d = New-Object IO.DriveInfo($root)
        if ($d.IsReady) { return $d.AvailableFreeSpace } else { return -1 }
    }
    catch { return -1 }
}

function Format-Size {
    [CmdletBinding()] param([double]$Bytes)
    if ($Bytes -lt 0) { return '-' }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f [int]$Bytes)
}

function New-ShortId {
    [CmdletBinding()] param([string]$Prefix = '')
    return $Prefix + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 4)
}

#endregion

#region ───────────────────────── 配置（多项目） ─────────────────────────

function New-DefaultProject {
    [CmdletBinding()]
    param([string]$Id, [string]$Name)
    [pscustomobject]@{
        id          = $Id
        name        = $Name
        source      = ''
        target      = ''
        exclude     = @()
        keep        = 20
        preCommand  = ''
        postCommand = ''
        note        = ''
    }
}

function Get-SyncConfigPath {
    [CmdletBinding()] param([string]$Root)
    if (-not $Root) { $Root = Get-SyncToolRoot }
    Join-Path $Root 'projects.json'
}

function Get-SyncConfig {
    <# 读取 projects.json；不存在则返回默认空配置。#>
    [CmdletBinding()] param([string]$Path)
    if (-not $Path) { $Path = Get-SyncConfigPath }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ version = 2; dataRoot = 'data'; defaultKeep = 20; projects = @() }
    }
    $raw = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{ version = 2; dataRoot = 'data'; defaultKeep = 20; projects = @() }
    }
    $cfg = $raw | ConvertFrom-Json
    # 补齐缺省字段，避免下游到处判空
    if (-not $cfg.PSObject.Properties['projects']) { $cfg | Add-Member -NotePropertyName projects -NotePropertyValue @() }
    if (-not $cfg.projects) { $cfg.projects = @() }
    if (-not $cfg.PSObject.Properties['dataRoot'] -or -not $cfg.dataRoot) {
        $cfg | Add-Member -NotePropertyName dataRoot -NotePropertyValue 'data' -Force
    }
    if (-not $cfg.PSObject.Properties['defaultKeep'] -or -not $cfg.defaultKeep) {
        $cfg | Add-Member -NotePropertyName defaultKeep -NotePropertyValue 20 -Force
    }
    if (-not $cfg.PSObject.Properties['version']) {
        $cfg | Add-Member -NotePropertyName version -NotePropertyValue 2
    }
    $fixed = @()
    foreach ($p in @($cfg.projects)) {
        if (-not $p.PSObject.Properties['id'] -or -not $p.id) { continue }
        if (-not $p.PSObject.Properties['name'])   { $p | Add-Member -NotePropertyName name -NotePropertyValue $p.id }
        if (-not $p.PSObject.Properties['source']) { $p | Add-Member -NotePropertyName source -NotePropertyValue '' }
        if (-not $p.PSObject.Properties['target']) { $p | Add-Member -NotePropertyName target -NotePropertyValue '' }
        if (-not $p.PSObject.Properties['exclude'] -or $null -eq $p.exclude) { $p | Add-Member -NotePropertyName exclude -NotePropertyValue @() }
        if (-not $p.PSObject.Properties['keep'])   { $p | Add-Member -NotePropertyName keep -NotePropertyValue 0 }
        if (-not $p.PSObject.Properties['preCommand'])  { $p | Add-Member -NotePropertyName preCommand  -NotePropertyValue '' }
        if (-not $p.PSObject.Properties['postCommand']) { $p | Add-Member -NotePropertyName postCommand -NotePropertyValue '' }
        if (-not $p.PSObject.Properties['note'])   { $p | Add-Member -NotePropertyName note -NotePropertyValue '' }
        $fixed += $p
    }
    $cfg.projects = $fixed
    $cfg
}

function Save-SyncConfig {
    [CmdletBinding()] param([Parameter(Mandatory)]$Config, [string]$Path)
    if (-not $Path) { $Path = Get-SyncConfigPath }
    $json = $Config | ConvertTo-Json -Depth 12
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($Path, $json, $script:Utf8NoBom)
    $Path
}

function Get-SyncProject {
    [CmdletBinding()] param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Id)
    $p = @($Config.projects | Where-Object { $_.id -eq $Id })
    if ($p.Count -eq 0) {
        $known = (@($Config.projects | ForEach-Object { $_.id }) -join ', ')
        throw ("找不到项目 [{0}]。已配置的项目：{1}" -f $Id, $(if ($known) { $known } else { '（无）' }))
    }
    $p[0]
}

function Get-ProjectPaths {
    <# 解析一个项目的全部落盘路径。#>
    [CmdletBinding()] param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Project, [string]$Root)
    if (-not $Root) { $Root = Get-SyncToolRoot }
    $dataRoot = Resolve-AnyPath -Path ([string]$Config.dataRoot) -Base $Root
    $projDir  = Join-Path (Join-Path $dataRoot 'projects') $Project.id
    [pscustomobject]@{
        Root           = $Root
        DataRoot       = $dataRoot
        ProjectDir     = $projDir
        StateDir       = Join-Path $projDir 'state'
        IncrementsDir  = Join-Path $projDir 'increments'
        InboxDir       = Join-Path $projDir 'inbox'
        LogDir         = Join-Path $projDir 'logs'
        StateFile      = Join-Path (Join-Path $projDir 'state') $script:STATE_FILE
        AppliedFile    = Join-Path (Join-Path $projDir 'state') $script:APPLIED_FILE
        ExportsFile    = Join-Path (Join-Path $projDir 'state') $script:EXPORTS_FILE
        Source         = Resolve-AnyPath -Path ([string]$Project.source) -Base $Root
        Target         = Resolve-AnyPath -Path ([string]$Project.target) -Base $Root
    }
}

function Initialize-ProjectDirs {
    [CmdletBinding()] param([Parameter(Mandatory)]$Paths)
    foreach ($d in @($Paths.DataRoot, $Paths.ProjectDir, $Paths.StateDir, $Paths.IncrementsDir, $Paths.LogDir, (Join-Path $Paths.LogDir 'jobs'))) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }
}

#endregion

# ───────────────────────── 排除规则 / 扫描 ─────────────────────────

function ConvertTo-ExcludeRegex {
    <#
      把用户写的排除规则转成正则（对相对路径，分隔符统一为 /）：
        *.log            文件名通配（任意层级）
        node_modules     任意一段目录名等于它即排除
        docs/tmp         相对路径前缀
        **/cache/**      任意层级的 cache 目录
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Pattern)
    $p = $Pattern.Trim().Replace('\', '/').TrimEnd('/')
    if (-not $p) { return $null }
    $hasSlash = $p.Contains('/')
    $escaped = [Regex]::Escape($p)
    # Regex.Escape 会把 * 转成 \*，还原后再替换
    $escaped = $escaped.Replace('\*\*/', '(?:.*/)?').Replace('\*\*', '.*')
    $escaped = $escaped.Replace('\*', '[^/]*').Replace('\?', '[^/]')
    if ($hasSlash) { return '^(?:.*/)?' + $escaped + '(?:/.*)?$' }
    return '(?:^|/)' + $escaped + '(?:/.*)?$'
}

function New-ExcludeMatcher {
    <# 预编译规则集合，返回一个脚本块，重复匹配时比每次解析快。#>
    [CmdletBinding()] param($Patterns)
    $regexes = New-Object System.Collections.Generic.List[object]
    foreach ($pat in @($Patterns)) {
        if (-not $pat) { continue }
        $r = ConvertTo-ExcludeRegex -Pattern ([string]$pat)
        if ($r) { $regexes.Add((New-Object System.Text.RegularExpressions.Regex($r, [Text.RegularExpressions.RegexOptions]::IgnoreCase))) }
    }
    if ($regexes.Count -eq 0) { return { param($rel) return $false } }
    return {
        param([string]$rel)
        foreach ($rx in $regexes) { if ($rx.IsMatch($rel)) { return $true } }
        return $false
    }.GetNewClosure()
}

function Get-ScanIndex {
    <#
      枚举源目录，返回有序哈希表：相对路径 -> FileInfo。
      跳过重链接（符号链接/联接点），跳过命中排除规则的文件与目录。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        $ExcludePatterns
    )
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw ("源目录不存在：{0}" -f $Source) }
    $matcher = New-ExcludeMatcher -Patterns $ExcludePatterns
    $index = [ordered]@{}
    $skipped = 0
    $srcLen = $Source.TrimEnd('\').Length + 1

    $all = Get-ChildItem -LiteralPath $Source -Recurse -File -Force -ErrorAction SilentlyContinue
    foreach ($f in $all) {
        if (Test-IsReparsePoint $f) { continue }
        $rel = $f.FullName.Substring($srcLen).Replace('\', '/')
        if (& $matcher $rel) { $skipped++; continue }
        $index[$rel] = $f
    }
    return [pscustomobject]@{ Index = $index; Skipped = $skipped }
}

#region ───────────────────────── 状态文件 ─────────────────────────

function Get-SyncState {
    <#
      读取 state.txt：
        id= / base= / created= / fileTotal= / totalBytes= / source=
        [files]
        大小|UTC ticks|相对路径
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $st = @{
        Id = ''; Base = ''; Created = ''; Source = ''
        FileTotal = 0; TotalBytes = [long]0
        Files = @{}
    }
    $section = 'header'
    foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) {
        if ($line -eq '[files]') { $section = 'files'; continue }
        if ($section -eq 'header') {
            $i = $line.IndexOf('=')
            if ($i -gt 0) {
                $k = $line.Substring(0, $i); $v = $line.Substring($i + 1)
                switch ($k) {
                    'id'         { $st.Id = $v }
                    'base'       { $st.Base = $v }
                    'created'    { $st.Created = $v }
                    'source'     { $st.Source = $v }
                    'fileTotal'  { $st.FileTotal = [int]$v }
                    'totalBytes' { $st.TotalBytes = [long]$v }
                }
            }
        }
        elseif ($section -eq 'files' -and $line) {
            $a = $line -split '\|', 3
            if ($a.Count -eq 3) { $st.Files[$a[2]] = @{ Size = [long]$a[0]; Ticks = [long]$a[1] } }
        }
    }
    $st
}

function Save-SyncState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Id,
        [string]$Base = '',
        [string]$Source = '',
        [Parameter(Mandatory)]$Entries   # [ordered]@{ rel = FileInfo }
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('id=' + $Id)
    $lines.Add('base=' + $Base)
    $lines.Add('created=' + [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))
    $lines.Add('source=' + $Source)
    $lines.Add('fileTotal=' + $Entries.Count)
    $total = [long]0
    foreach ($k in $Entries.Keys) { $total += $Entries[$k].Length }
    $lines.Add('totalBytes=' + $total)
    $lines.Add('[files]')
    foreach ($rel in ($Entries.Keys | Sort-Object)) {
        $f = $Entries[$rel]
        $lines.Add(('{0}|{1}|{2}' -f $f.Length, $f.LastWriteTimeUtc.Ticks, $rel))
    }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllLines($Path, $lines, $script:Utf8NoBom)
}

function Get-AppliedState {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{ lastId = ''; applied = @(); updatedAt = '' } }
    try {
        $o = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if (-not $o.PSObject.Properties['applied'] -or $null -eq $o.applied) {
            $o | Add-Member -NotePropertyName applied -NotePropertyValue @()
        }
        return @{ lastId = [string]$o.lastId; applied = @($o.applied); updatedAt = [string]$o.updatedAt }
    }
    catch { return @{ lastId = ''; applied = @(); updatedAt = '' } }
}

function Save-AppliedState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string]$LastId, $Applied)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $obj = [pscustomobject]@{
        lastId    = $LastId
        applied   = @($Applied)
        updatedAt = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
    }
    [IO.File]::WriteAllText($Path, ($obj | ConvertTo-Json -Depth 5), $script:Utf8NoBom)
}

#endregion

#region ───────────────────────── 包（zip）读写 ─────────────────────────

function Open-SyncZip {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Path)
    New-Object IO.Compression.ZipArchive(
        ([IO.File]::OpenRead($Path)), [IO.Compression.ZipArchiveMode]::Read, $false, [Text.Encoding]::UTF8)
}

function Get-PackageMeta {
    <# 读取包内 inc.meta。#>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$ZipPath)
    $zip = Open-SyncZip -Path $ZipPath
    try {
        $mEntry = $zip.GetEntry($script:META_ENTRY)
        if (-not $mEntry) { throw ("缺少 {0}，不是本工具的备份包：{1}" -f $script:META_ENTRY, $ZipPath) }
        $sr = New-Object IO.StreamReader($mEntry.Open(), [Text.Encoding]::UTF8)
        try { $text = $sr.ReadToEnd() } finally { $sr.Dispose() }

        $meta = @{ ZipPath = $ZipPath; Name = (Split-Path -Leaf $ZipPath); Files = @(); Deleted = @(); Project = ''; Host = ''; Source = '' }
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
                        'project' { $meta.Project = $line.Substring($i + 1) }
                        'host'    { $meta.Host = $line.Substring($i + 1) }
                        'source'  { $meta.Source = $line.Substring($i + 1) }
                    }
                }
            }
            elseif ($section -eq 'files') {
                if ($line) {
                    $a = $line -split '\|', 3
                    if ($a.Count -eq 3) { $meta.Files += @{ Rel = $a[2]; Sha = $a[0]; Size = [long]$a[1] } }
                }
            }
            elseif ($line) { $meta.Deleted += $line }
        }
        if (-not $meta.Id) { throw ("inc.meta 缺少 id：{0}" -f $ZipPath) }
        if (-not $meta.PSObject.Properties['Size']) {
            $meta.Size = (Get-Item -LiteralPath $ZipPath).Length
        }
        return $meta
    }
    finally { $zip.Dispose() }
}

function Get-PackageList {
    <# 扫描目录下的全部包，返回元信息数组（读不出的一律跳过并告警）。#>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Dir, [switch]$Quiet)
    $list = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $list }
    foreach ($z in @(Get-ChildItem -LiteralPath $Dir -File -Filter '*.zip' | Sort-Object Name)) {
        try { $list.Add((Get-PackageMeta -ZipPath $z.FullName)) }
        catch { if (-not $Quiet) { Write-Log -Message ("跳过无法读取的包 {0}：{1}" -f $z.Name, $_.Exception.Message) -Level 'WARN' } }
    }
    $list
}

function Get-PackageIdTimestamp {
    <# 包 ID 形如 F-20260928-102019-be67：第 3 字符起是 yyyyMMdd-HHmmss，据此比较新旧。#>
    [CmdletBinding()] param([string]$Id)
    if ($Id -and $Id.Length -ge 17) { $Id.Substring(2, 15) } else { '' }
}

function Get-Sha256 {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Remove-PathQuiet {
    <#
      安静地删除文件/目录树：任何失败都只记一条告警，绝不向上抛异常。
      临时目录清理属于"收尾动作"，不能因为它失败而让整个备份/还原任务失败。
      优先用 .NET API（比 cmdlet 快，且在受限环境里更不容易被拦截）。
    #>
    # 注意：-Path 故意不加 [Parameter(Mandatory)]。Mandatory 的校验发生在函数体之前，
    # 传 $null / 空串会在绑定期直接抛「无法将参数绑定到参数"Path"，因为该参数为空字符串」，
    # 后面的空值保护根本来不及执行 —— 这与本函数「收尾清理、绝不抛异常」的契约直接矛盾。
    [CmdletBinding()] param([string]$Path, [switch]$Warn)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try { if ([IO.Directory]::Exists($Path)) { [IO.Directory]::Delete($Path, $true) } } catch { }
    try { if ([IO.File]::Exists($Path)) { [IO.File]::Delete($Path) } } catch { }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    if ((Test-Path -LiteralPath $Path) -and $Warn) {
        Write-Log -Message ('临时文件清理失败（不影响结果，可稍后手工删除）：{0}' -f $Path) -Level 'WARN'
    }
}

function Remove-FileQuiet {
    <# 删除单个文件；返回是否已不存在。优先 .NET API。#>
    # 同 Remove-PathQuiet：-Path 不加 Mandatory，空路径视为「无需删除」。
    [CmdletBinding()] param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $true }
    try { if ([IO.File]::Exists($Path)) { [IO.File]::Delete($Path) } } catch { }
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    try { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue } catch { }
    return (-not (Test-Path -LiteralPath $Path))
}

function Remove-FileAndEmptyParents {
    <#
      删除文件，并向上清理变空的父目录（不会越过 Root）。
      返回对象：Existed = 文件原本是否存在；Deleted = 是否已确认删除。
      删除用 .NET API 实现：比 cmdlet 快，且在受限环境中更不容易被拦截；
      删除被占用/无权限时不会抛异常，由调用方决定如何记录。
    #>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$RelPath)
    $p = Join-Path $Root $RelPath
    $existed = Test-Path -LiteralPath $p
    $deleted = Remove-FileQuiet -Path $p
    if ($deleted) {
        $parent = Split-Path -Parent $p
        while ($parent -and $parent.Length -gt $Root.Length -and $parent.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) {
            if (@(@(Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue)).Count -gt 0) { break }
            try { [IO.Directory]::Delete($parent, $false) } catch { break }
            $parent = Split-Path -Parent $parent
        }
    }
    [pscustomobject]@{ Existed = $existed; Deleted = $deleted; Path = $RelPath }
}

#endregion

#region ───────────────────────── 打包（备份端） ─────────────────────────

function Get-PendingChanges {
    <# 计算相对上次快照的差异（新增/修改 + 删除）。#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ScanIndex,
        $State,
        [switch]$Full
    )
    $changed = New-Object System.Collections.Generic.List[string]
    $deleted = New-Object System.Collections.Generic.List[string]
    $src = $ScanIndex.Index

    foreach ($rel in @($src.Keys)) {
        if ($Full -or -not $State) { $changed.Add($rel); continue }
        $f = $src[$rel]
        $b = $State.Files[$rel]
        if ($b -and $b.Size -eq $f.Length -and $b.Ticks -eq $f.LastWriteTimeUtc.Ticks) { continue }
        $changed.Add($rel)
    }
    if ($State -and -not $Full) {
        foreach ($rel in @($State.Files.Keys)) {
            if (-not $src.Contains($rel)) { $deleted.Add($rel) }
        }
    }
    [pscustomobject]@{ Changed = $changed; Deleted = $deleted }
}

function Invoke-SyncBackup {
    <#
      生成备份包。首次或重新对齐用 -Full；日常直接跑即为增量。
      返回：包路径（无变化时为 $null）
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Project,
        [switch]$Full,
        [string]$Target,               # 生成后把包拷到这里（U盘/共享/目录）
        [int]$Keep = -1,               # 保留最近 N 个包，-1 表示用项目配置
        [string]$LogFile,
        [switch]$NoHook,               # 不执行 preCommand/postCommand
        [switch]$DryRun,               # 只算差异，不生成包
        [switch]$SkipCleanup
    )
    if ($LogFile) { Set-SyncLogFile -Path $LogFile }
    $Paths = Get-ProjectPaths -Config $Config -Project $Project
    Initialize-ProjectDirs -Paths $Paths

    if (-not $Project.source) { throw ("项目 [{0}] 没有配置源目录（source）。" -f $Project.id) }
    $Source = $Paths.Source
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw ("源目录不存在：{0}" -f $Source) }
    if (Test-NestedPath $Source $Paths.ProjectDir) { throw ("源目录与数据目录不能互相嵌套：{0} / {1}" -f $Source, $Paths.ProjectDir) }

    $hookFailed = $false
    try {
        # ---------- 前置命令（如 docker pause） ----------
        if (-not $NoHook -and $Project.preCommand) {
            Write-Log -Message ("执行前置命令：{0}" -f $Project.preCommand) -Level 'STEP'
            & cmd.exe /c $Project.preCommand 2>&1 | ForEach-Object { if ($_) { Write-Host "    $_" -ForegroundColor DarkGray } }
            if ($LASTEXITCODE -ne 0) { $hookFailed = $true; throw ("前置命令失败（退出码 {0}），已中止打包。" -f $LASTEXITCODE) }
        }

        # ---------- 基线 ----------
        $state = Get-SyncState -Path $Paths.StateFile
        if ($Full) {
            Write-Log -Message '本次生成【全量包】：包含全部文件，作为新链条的起点。' -Level 'STEP'
            $basisId = ''
        }
        elseif ($state -and $state.Id) {
            Write-Log -Message ("基线：上次快照 {0}（{1}），清单 {2} 个文件" -f $state.Id, $state.Created, $state.Files.Count) -Level 'INFO'
            $basisId = $state.Id
        }
        else {
            throw '没有可用的同步状态。首次使用（或状态丢失）请先执行一次全量备份。'
        }

        # ---------- 扫描 ----------
        Write-Log -Message ("扫描源目录：{0}" -f $Source) -Level 'STEP'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $scan = Get-ScanIndex -Source $Source -ExcludePatterns $Project.exclude
        $sw.Stop()
        Write-Log -Message ("源目录文件 {0} 个（已排除 {1} 个，用时 {2:N1}s）" -f $scan.Index.Count, $scan.Skipped, $sw.Elapsed.TotalSeconds) -Level 'INFO'

        $diff = Get-PendingChanges -ScanIndex $scan -State $state -Full:$Full
        Write-Log -Message ("差异：新增/修改 {0} 个，删除 {1} 个" -f $diff.Changed.Count, $diff.Deleted.Count) -Level 'INFO'

        if ($DryRun) {
            $n = [Math]::Min(30, $diff.Changed.Count)
            for ($i = 0; $i -lt $n; $i++) { Write-Log -Message ('  + ' + $diff.Changed[$i]) -Level 'INFO' }
            if ($diff.Changed.Count -gt $n) { Write-Log -Message ('  ... 其余 {0} 个' -f ($diff.Changed.Count - $n)) -Level 'INFO' }
            $n = [Math]::Min(30, $diff.Deleted.Count)
            for ($i = 0; $i -lt $n; $i++) { Write-Log -Message ('  - ' + $diff.Deleted[$i]) -Level 'INFO' }
            if ($diff.Deleted.Count -gt $n) { Write-Log -Message ('  ... 其余 {0} 个' -f ($diff.Deleted.Count - $n)) -Level 'INFO' }
            Write-Log -Message '（预览模式：未生成任何包）' -Level 'OK'
            return $null
        }

        # ---------- 生成包 ----------
        $newId  = New-ShortId -Prefix $(if ($Full) { 'F-' } else { 'I-' })
        $zipPath = $null
        $failed = @{}

        if ($diff.Changed.Count -eq 0 -and $diff.Deleted.Count -eq 0) {
            Write-Log -Message '没有任何变化，未生成包。' -Level 'OK'
        }
        else {
            $tmpZip = Join-Path $Paths.IncrementsDir ('.' + $newId + '.tmp')
            $zip = New-Object IO.Compression.ZipArchive(
                ([IO.File]::Open($tmpZip, [IO.FileMode]::CreateNew)),
                [IO.Compression.ZipArchiveMode]::Create, $false, [Text.Encoding]::UTF8)
            $metaLines = New-Object System.Collections.Generic.List[string]
            $packed = 0
            $packedBytes = [long]0
            try {
                foreach ($rel in $diff.Changed) {
                    $f = $scan.Index[$rel]
                    try {
                        $sha = Get-Sha256 -Path $f.FullName
                        $entry = $zip.CreateEntry($script:FILES_ROOT + $rel)
                        $entry.LastWriteTime = $f.LastWriteTime
                        $in = [IO.File]::OpenRead($f.FullName)
                        $out = $entry.Open()
                        try { $in.CopyTo($out) } finally { $in.Dispose(); $out.Dispose() }
                        $metaLines.Add(('{0}|{1}|{2}' -f $sha, $f.Length, $rel))
                        $packed++; $packedBytes += $f.Length
                    }
                    catch {
                        $failed[$rel] = $_.Exception.Message
                        Write-Log -Message ("打包失败（下次自动重试）：{0} —— {1}" -f $rel, $_.Exception.Message) -Level 'WARN'
                    }
                }

                $meta = New-Object System.Collections.Generic.List[string]
                $meta.Add('id=' + $newId)
                $meta.Add('base=' + $basisId)
                $meta.Add('type=' + $(if ($Full) { 'full' } else { 'incremental' }))
                $meta.Add('created=' + [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))
                $meta.Add('project=' + $Project.id)
                $meta.Add('projectName=' + $Project.name)
                $meta.Add('host=' + (Get-SyncHostName))
                $meta.Add('source=' + $Source)
                $meta.Add('fileTotal=' + $scan.Index.Count)
                $meta.Add('copied=' + $packed)
                $meta.Add('rawBytes=' + $packedBytes)
                $meta.Add('deleted=' + $diff.Deleted.Count)
                $meta.Add('failed=' + $failed.Count)
                $meta.Add('toolVersion=' + $script:SyncKitVersion)
                $meta.Add('[files]')
                foreach ($l in $metaLines) { $meta.Add($l) }
                $meta.Add('[deleted]')
                foreach ($rel in $diff.Deleted) { $meta.Add($rel) }

                $mEntry = $zip.CreateEntry($script:META_ENTRY)
                $swr = New-Object IO.StreamWriter($mEntry.Open(), (New-Object Text.UTF8Encoding($false)))
                try { $swr.Write(($meta -join "`r`n")) } finally { $swr.Dispose() }
            }
            finally { $zip.Dispose() }

            Move-Item -LiteralPath $tmpZip -Destination (Join-Path $Paths.IncrementsDir ($newId + '.zip')) -Force
            $zipPath = Join-Path $Paths.IncrementsDir ($newId + '.zip')

            # 自检：重开 zip 确认文件条目数一致
            $chk = Open-SyncZip -Path $zipPath
            try { $entryCount = @($chk.Entries | Where-Object { $_.FullName.StartsWith($script:FILES_ROOT) }).Count }
            finally { $chk.Dispose() }
            if ($entryCount -ne $packed) { throw ("自检失败：包内文件条目 {0} != 打包数 {1}" -f $entryCount, $packed) }

            # 整包 SHA256（供转移与校验用）
            $pkgSha = Get-Sha256 -Path $zipPath
            [IO.File]::WriteAllText($zipPath + '.sha256', ($pkgSha + '  ' + (Split-Path -Leaf $zipPath) + "`r`n"), $script:Utf8NoBom)

            $kindName = if ($Full) { '全量包' } else { '增量包' }
            Write-Log -Message ("{0}已生成：{1}.zip（{2}，{3} 个文件，记录删除 {4}）" -f `
                $kindName, $newId, (Format-Size (Get-Item -LiteralPath $zipPath).Length), $packed, $diff.Deleted.Count) -Level 'OK'
            Write-Log -Message ("包 SHA256：{0}" -f $pkgSha) -Level 'INFO'
        }

        # ---------- 更新状态（排除失败文件，便于下次重试） ----------
        if ($failed.Count -eq 0) {
            Save-SyncState -Path $Paths.StateFile -Id $(if ($zipPath) { $newId } else { $state.Id }) -Base $basisId -Source $Source -Entries $scan.Index
            Write-Log -Message ("状态已更新：{0}" -f $Paths.StateFile) -Level 'INFO'
        }
        else {
            $okIndex = [ordered]@{}
            foreach ($rel in $scan.Index.Keys) { if (-not $failed.ContainsKey($rel)) { $okIndex[$rel] = $scan.Index[$rel] } }
            Save-SyncState -Path $Paths.StateFile -Id $(if ($zipPath) { $newId } else { $state.Id }) -Base $basisId -Source $Source -Entries $okIndex
            Write-Log -Message ("状态已更新（{0} 个失败文件未记入，下次会自动重试）" -f $failed.Count) -Level 'WARN'
        }

        # ---------- 清理旧包 ----------
        $keepN = $Keep
        if ($keepN -lt 0) { $keepN = [int]$Project.keep; if ($keepN -le 0) { $keepN = [int]$Config.defaultKeep } }
        if ($keepN -gt 0 -and -not $SkipCleanup) {
            Invoke-PackageCleanup -Project $Project -Paths $Paths -Keep $keepN
        }

        # ---------- 拷贝到目标 ----------
        if ($Target -and $zipPath) {
            $t = Resolve-AnyPath -Path $Target
            if (Test-Path -LiteralPath $t -PathType Container) {
                Copy-Item -LiteralPath $zipPath -Destination (Join-Path $t (Split-Path -Leaf $zipPath)) -Force
                Copy-Item -LiteralPath ($zipPath + '.sha256') -Destination (Join-Path $t (Split-Path -Leaf $zipPath) + '.sha256') -Force -ErrorAction SilentlyContinue
                Write-Log -Message ("包已拷贝到：{0}" -f $t) -Level 'OK'
            }
            else { Write-Log -Message ("目标不可用，未拷贝：{0}" -f $t) -Level 'WARN' }
        }

        return $zipPath
    }
    finally {
        if (-not $NoHook -and $Project.postCommand) {
            Write-Log -Message ("执行后置命令：{0}" -f $Project.postCommand) -Level 'STEP'
            & cmd.exe /c $Project.postCommand 2>&1 | ForEach-Object { if ($_) { Write-Host "    $_" -ForegroundColor DarkGray } }
            if ($LASTEXITCODE -ne 0) { Write-Log -Message ("后置命令失败（退出码 {0}），请手动检查。" -f $LASTEXITCODE) -Level 'WARN' }
        }
    }
}

function Invoke-PackageCleanup {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Project, [Parameter(Mandatory)]$Paths, [int]$Keep = 20)
    $all = @(Get-ChildItem -LiteralPath $Paths.IncrementsDir -File -Filter '*.zip' | Sort-Object Name -Descending)
    if ($all.Count -le $Keep) { return }
    foreach ($z in ($all | Select-Object -Skip $Keep)) {
        Write-Log -Message ("清理旧包：{0}" -f $z.Name) -Level 'INFO'
        Remove-FileQuiet -Path $z.FullName | Out-Null
        Remove-FileQuiet -Path ($z.FullName + '.sha256') | Out-Null
    }
}

#endregion

#region ───────────────────────── 应用（还原端） ─────────────────────────

function Resolve-ApplyChain {
    <# 沿 base 链算出"能接上当前状态"的包序列。#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Metas,
        [string]$CurrentId = '',
        [switch]$NoRealign
    )
    $chain = New-Object System.Collections.Generic.List[object]
    $chained = @{}
    $pointer = $CurrentId
    $realigned = $false
    $notes = New-Object System.Collections.Generic.List[string]

    while ($true) {
        if ($pointer -eq '') {
            $cand = @($Metas | Where-Object { (-not $chained.ContainsKey($_.Id)) -and ($_.Type -eq 'full') })
        }
        else {
            $cand = @($Metas | Where-Object { (-not $chained.ContainsKey($_.Id)) -and ($_.Base -eq $pointer) })
            if ($cand.Count -eq 0 -and -not $realigned -and -not $NoRealign) {
                $nowTs = Get-PackageIdTimestamp -Id $pointer
                $cand = @($Metas | Where-Object {
                    (-not $chained.ContainsKey($_.Id)) -and ($_.Type -eq 'full') -and ((Get-PackageIdTimestamp -Id $_.Id) -gt $nowTs)
                } | Sort-Object Id -Descending | Select-Object -First 1)
                if ($cand.Count -gt 0) {
                    $realigned = $true
                    $notes.Add(("当前状态 {0} 之后没有增量包，改用更新的全量包重新对齐：{1}" -f $pointer, $cand[0].Id))
                }
            }
        }
        if ($cand.Count -eq 0) { break }
        if ($cand.Count -gt 1) {
            $ids = ($cand | ForEach-Object { $_.Id }) -join ', '
            $notes.Add(("同一位置有多个包（{0}），按 ID 取最新。" -f $ids))
            $cand = @($cand | Sort-Object Id -Descending)
        }
        $c = $cand[0]
        $chain.Add($c); $chained[$c.Id] = $true; $pointer = $c.Id
    }

    $orphan = New-Object System.Collections.Generic.List[object]
    foreach ($m in @($Metas)) {
        if (-not $chained.ContainsKey($m.Id)) { $orphan.Add($m) }
    }
    [pscustomobject]@{ Chain = $chain; CurrentId = $pointer; Orphans = $orphan; Notes = $notes }
}

function Invoke-SyncRestore {
    <#
      把 inbox（或指定目录）中的包按链序应用到目标目录。
      -Plan 只预览；应用操作可安全重复。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Project,
        [string]$TargetDir,          # 覆盖项目配置的 target
        [string]$InboxDir,           # 覆盖默认 inbox（转移包模式会用到）
        [string]$StateFile,          # 覆盖 applied.json 路径
        [switch]$Plan,
        [switch]$Force,              # 忽略包内 project 与当前项目不一致的警告
        [string]$LogFile
    )
    if ($LogFile) { Set-SyncLogFile -Path $LogFile }
    $Paths = Get-ProjectPaths -Config $Config -Project $Project
    Initialize-ProjectDirs -Paths $Paths

    $dest = if ($TargetDir) { Resolve-AnyPath -Path $TargetDir } else { $Paths.Target }
    if (-not $dest) { throw ("项目 [{0}] 没有配置目标目录（target）。" -f $Project.id) }
    $inbox = if ($InboxDir) { Resolve-AnyPath -Path $InboxDir } else { $Paths.InboxDir }
    $appliedPath = if ($StateFile) { $StateFile } else { $Paths.AppliedFile }

    if (Test-NestedPath $dest $inbox) { throw ("目标目录与收件箱目录不能互相嵌套：{0} / {1}" -f $dest, $inbox) }

    Write-Log -Message ("目标目录：{0}" -f $dest) -Level 'STEP'
    Write-Log -Message ("收件箱：{0}" -f $inbox) -Level 'INFO'

    # ---------- 读进度 ----------
    $state = Get-AppliedState -Path $appliedPath
    if ($state.lastId) {
        Write-Log -Message ("当前进度：已应用到 {0}（{1}）" -f $state.lastId, $state.updatedAt) -Level 'INFO'
        if (-not (Test-Path -LiteralPath $dest -PathType Container)) {
            Write-Log -Message ("进度显示已应用过，但目标目录不存在：{0}。若为误拷进度文件，删除后重跑即可。" -f $dest) -Level 'WARN'
        }
        else {
            $n = @(Get-ChildItem -LiteralPath $dest -Recurse -File -Force -ErrorAction SilentlyContinue).Count
            if ($n -eq 0) { Write-Log -Message '进度存在但目标目录为空：可能是误拷了别处的进度文件，删除状态文件后重跑即可。' -Level 'WARN' }
        }
    }
    else {
        if (Test-Path -LiteralPath $dest -PathType Container) {
            $n = @(Get-ChildItem -LiteralPath $dest -Recurse -File -Force -ErrorAction SilentlyContinue).Count
            if ($n -gt 0) { Write-Log -Message ("目标目录已有 {0} 个文件但没有进度记录：请放入全量包重新对齐（应用全量包会镜像清理多余文件）。" -f $n) -Level 'WARN' }
        }
    }

    if (-not (Test-Path -LiteralPath $inbox -PathType Container)) {
        Write-Log -Message ("没有待应用的包（目录不存在：{0}）。" -f $inbox) -Level 'OK'
        return 0
    }

    # ---------- 读包 ----------
    $metas = @(Get-PackageList -Dir $inbox)
    if ($metas.Count -eq 0) {
        Write-Log -Message ("没有待应用的包：{0}" -f $inbox) -Level 'OK'
        return 0
    }
    Write-Log -Message ("待应用目录中有 {0} 个包" -f $metas.Count) -Level 'INFO'

    if (-not $Force) {
        $other = @($metas | Where-Object { $_.Project -and $_.Project -ne $Project.id })
        if ($other.Count -gt 0) {
            $ids = (@($other | ForEach-Object { $_.Name + '(项目=' + $_.Project + ')' }) | Select-Object -First 5) -join ', '
            throw ("收件箱里有属于其它项目的包：{0}。请改用对应项目应用，或用 -Force 强行继续。" -f $ids)
        }
    }

    $res = Resolve-ApplyChain -Metas $metas -CurrentId $state.lastId
    foreach ($n in $res.Notes) { Write-Log -Message $n -Level 'WARN' }
    foreach ($m in $res.Orphans) {
        if ($state.lastId -eq '') {
            Write-Log -Message ("无法接入当前状态的包：{0} —— 当前没有进度，链头必须是全量包（F-*.zip）" -f $m.Name) -Level 'WARN'
        }
        elseif ($m.Type -eq 'full') {
            Write-Log -Message ("跳过全量包：{0} —— 不比当前状态新，或已有更新的全量包被应用" -f $m.Name) -Level 'WARN'
        }
        else {
            Write-Log -Message ("无法接入当前状态的包：{0}（base={1}，当前={2}）—— 可能缺少中间包或尚未转移过来" -f $m.Name, $m.Base, $res.CurrentId) -Level 'WARN'
        }
    }

    if ($res.Chain.Count -eq 0) {
        Write-Log -Message '没有可应用的包（见上方提示）。' -Level 'ERROR'
        return 1
    }

    Write-Log -Message ("将按序应用 {0} 个包：{1}" -f $res.Chain.Count, (($res.Chain | ForEach-Object { $_.Id }) -join '  ->  ')) -Level 'STEP'
    if ($Plan) { Write-Log -Message '（预览模式：未做任何改动）' -Level 'OK'; return 0 }

    # ---------- 逐包应用 ----------
    $appliedDir = Join-Path $inbox 'applied'
    New-Item -ItemType Directory -Force -Path $appliedDir, $dest | Out-Null
    $appliedList = @($state.applied)
    $copiedTotal = 0; $deletedTotal = 0

    foreach ($m in $res.Chain) {
        $kind = if ($m.Type -eq 'full') { '全量包' } else { '增量包' }
        Write-Log -Message ("=== 应用{0} {1}（{2}，{3} 个文件，删除 {4}）===" -f `
            $kind, $m.Id, $(if ($m.Created) { $m.Created } else { '时间未知' }), $m.Files.Count, $m.Deleted.Count) -Level 'STEP'
        $tmp = Join-Path $env:TEMP ('synckit-apply-' + $m.Id)
        Remove-PathQuiet -Path $tmp
        try {
            # 1) 整包解压到临时目录
            $zip = Open-SyncZip -Path $m.ZipPath
            try {
                foreach ($e in $zip.Entries) {
                    if (-not $e.FullName.StartsWith($script:FILES_ROOT) -or $e.FullName.EndsWith('/')) { continue }
                    $rel = ($e.FullName.Substring($script:FILES_ROOT.Length)) -replace '/', '\'
                    $dst = Join-Path $tmp $rel
                    $parent = Split-Path -Parent $dst
                    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dst, $true)
                }
            }
            finally { $zip.Dispose() }

            # 2) 逐文件校验 SHA256，全部通过才落地
            foreach ($f in $m.Files) {
                $p = Join-Path $tmp $f.Rel
                if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw ("包内缺少文件：{0}" -f $f.Rel) }
                if ((Get-Sha256 -Path $p) -ne $f.Sha) { throw ("SHA256 校验失败：{0} —— 包可能拷贝损坏，请重新转移该包" -f $f.Rel) }
            }
            Write-Log -Message ("  校验通过：{0} 个文件 SHA256 一致" -f $m.Files.Count) -Level 'INFO'

            # 3) 落地
            foreach ($f in $m.Files) {
                $src = Join-Path $tmp $f.Rel
                $dst = Join-Path $dest ($f.Rel -replace '/', '\')
                $parent = Split-Path -Parent $dst
                if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
                Copy-Item -LiteralPath $src -Destination $dst -Force
                $copiedTotal++
            }

            # 4) 删除清单
            $delFail = New-Object System.Collections.Generic.List[string]
            foreach ($rel in $m.Deleted) {
                $r = Remove-FileAndEmptyParents -Root $dest -RelPath ($rel -replace '/', '\')
                if ($r.Deleted) {
                    if ($r.Existed) { Write-Log -Message ("  已删除：{0}" -f $rel) -Level 'INFO' }
                    $deletedTotal++
                }
                else {
                    Write-Log -Message ("  删除失败（文件可能被占用或只读）：{0}" -f $rel) -Level 'WARN'
                    $delFail.Add($rel)
                }
            }
            if ($delFail.Count -gt 0) {
                throw ("有 {0} 个文件未能删除（可能被其它程序占用）。包仍保留在收件箱，关闭占用程序后重跑本脚本即可。" -f $delFail.Count)
            }

            # 5) 全量包：镜像清理（保证与该全量包完全一致）
            if ($m.Type -eq 'full') {
                $inventory = @{}
                foreach ($f in $m.Files) { $inventory[$f.Rel] = $true }
                $extra = @(Get-ChildItem -LiteralPath $dest -Recurse -File -Force |
                    Where-Object { -not (Test-IsReparsePoint $_) } |
                    ForEach-Object { $_.FullName.Substring($dest.TrimEnd('\').Length + 1).Replace('\', '/') } |
                    Where-Object { -not $inventory.ContainsKey($_) })
                $extraFail = New-Object System.Collections.Generic.List[string]
                foreach ($rel in $extra) {
                    $r2 = Remove-FileAndEmptyParents -Root $dest -RelPath ($rel -replace '/', '\')
                    if ($r2.Deleted) { $deletedTotal++ } else { $extraFail.Add($rel) }
                }
                if ($extra.Count -gt 0) { Write-Log -Message ("  镜像清理：删除不在全量包清单内的文件 {0} 个" -f $extra.Count) -Level 'INFO' }
                if ($extraFail.Count -gt 0) {
                    Write-Log -Message ("  其中 {0} 个文件未能删除（可能被占用），目标目录尚未与全量包完全一致。" -f $extraFail.Count) -Level 'WARN'
                }
            }
        }
        finally {
            Remove-PathQuiet -Path $tmp -Warn
        }

        # 6) 移入 applied 并落盘进度（此后重跑不会重复应用）
        Move-Item -LiteralPath $m.ZipPath -Destination (Join-Path $appliedDir (Split-Path -Leaf $m.ZipPath)) -Force
        $shaSide = $m.ZipPath + '.sha256'
        if (Test-Path -LiteralPath $shaSide) { Move-Item -LiteralPath $shaSide -Destination $appliedDir -Force -ErrorAction SilentlyContinue }
        $appliedList = @($appliedList) + $m.Id
        Save-AppliedState -Path $appliedPath -LastId $m.Id -Applied $appliedList
        Write-Log -Message ("  完成，包已移入 applied" -f $appliedDir) -Level 'INFO'
    }

    $fileCount = @(Get-ChildItem -LiteralPath $dest -Recurse -File -Force -ErrorAction SilentlyContinue).Count
    Write-Log -Message ("全部完成：应用 {0} 个包，落地 {1} 个文件，删除 {2} 个；目标目录现有 {3} 个文件。" -f `
        $res.Chain.Count, $copiedTotal, $deletedTotal, $fileCount) -Level 'OK'
    Write-Log -Message ("当前状态：已应用到 {0}" -f $res.CurrentId) -Level 'OK'
    return 0
}

#endregion

#region ───────────────────────── 状态查询（界面用） ─────────────────────────

function Get-ProjectStatus {
    <#
      汇总一个项目的状态（只读，尽量少扫盘）：
        配置 / 包数量与占用 / 上次打包 / 待应用包 / 已应用到
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Project)
    $Paths = Get-ProjectPaths -Config $Config -Project $Project

    $st = Get-SyncState -Path $Paths.StateFile
    $packages = @()
    $pkgBytes = [long]0
    if (Test-Path -LiteralPath $Paths.IncrementsDir -PathType Container) {
        foreach ($z in @(Get-ChildItem -LiteralPath $Paths.IncrementsDir -File -Filter '*.zip')) {
            $packages += [pscustomobject]@{ Name = $z.Name; Size = $z.Length; Time = $z.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') }
            $pkgBytes += $z.Length
        }
    }
    $inbox = @()
    if (Test-Path -LiteralPath $Paths.InboxDir -PathType Container) {
        foreach ($z in @(Get-ChildItem -LiteralPath $Paths.InboxDir -File -Filter '*.zip')) {
            $inbox += [pscustomobject]@{ Name = $z.Name; Size = $z.Length; Time = $z.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') }
        }
    }
    $applied = Get-AppliedState -Path $Paths.AppliedFile
    $pending = 0
    if ($inbox.Count -gt 0) {
        $metas = Get-PackageList -Dir $Paths.InboxDir -Quiet
        $res = Resolve-ApplyChain -Metas $metas -CurrentId $applied.lastId
        $pending = $res.Chain.Count
    }

    $srcExists = $false; $srcFiles = 0; $srcBytes = [long]0
    if ($Project.source -and (Test-Path -LiteralPath $Paths.Source -PathType Container)) {
        $srcExists = $true
        if ($st) { $srcFiles = $st.FileTotal; $srcBytes = $st.TotalBytes }
    }

    [pscustomobject]@{
        id            = $Project.id
        name          = $Project.name
        source        = $Paths.Source
        target        = $Paths.Target
        sourceExists  = $srcExists
        targetExists  = [bool]($Paths.Target -and (Test-Path -LiteralPath $Paths.Target -PathType Container))
        exclude       = @($Project.exclude)
        keep          = [int]$Project.keep
        preCommand    = [string]$Project.preCommand
        postCommand   = [string]$Project.postCommand
        note          = [string]$Project.note
        lastPackId    = $(if ($st) { $st.Id } else { '' })
        lastPackTime  = $(if ($st) { $st.Created } else { '' })
        snapshotFiles = $(if ($st) { $st.FileTotal } else { 0 })
        snapshotBytes = $(if ($st) { $st.TotalBytes } else { 0 })
        packageCount  = $packages.Count
        packageBytes  = $pkgBytes
        latestPackage = $(if ($packages.Count -gt 0) { ($packages | Sort-Object Name -Descending)[0].Name } else { '' })
        inboxCount    = $inbox.Count
        pendingCount  = $pending
        appliedId     = $applied.lastId
        appliedTime   = $applied.updatedAt
        paths         = [pscustomobject]@{
            projectDir    = $Paths.ProjectDir
            incrementsDir = $Paths.IncrementsDir
            inboxDir      = $Paths.InboxDir
        }
        computedAt    = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
    }
}

function Get-ProjectPackages {
    <# 包历史（增量为准，含包内文件数与删除数）。#>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Project, [int]$Limit = 200)
    $Paths = Get-ProjectPaths -Config $Config -Project $Project
    $metas = @(Get-PackageList -Dir $Paths.IncrementsDir -Quiet | Sort-Object -Property @{ Expression = { Get-PackageIdTimestamp -Id $_.Id } } -Descending)
    $out = @()
    foreach ($m in ($metas | Select-Object -First $Limit)) {
        $out += [pscustomobject]@{
            id       = $m.Id
            type     = $m.Type
            base     = $m.Base
            created  = $m.Created
            files    = $m.Files.Count
            deleted  = $m.Deleted.Count
            size     = [long]$m.Size
            sizeText = Format-Size $m.Size
            name     = $m.Name
        }
    }
    $out
}

function Get-ProjectInbox {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Project)
    $Paths = Get-ProjectPaths -Config $Config -Project $Project
    $applied = Get-AppliedState -Path $Paths.AppliedFile
    $metas = @(Get-PackageList -Dir $Paths.InboxDir -Quiet)
    $res = Resolve-ApplyChain -Metas $metas -CurrentId $applied.lastId
    $chainIds = @{}
    foreach ($c in $res.Chain) { $chainIds[$c.Id] = $true }
    $out = @()
    foreach ($m in ($metas | Sort-Object -Property @{ Expression = { Get-PackageIdTimestamp -Id $_.Id } })) {
        $out += [pscustomobject]@{
            id      = $m.Id
            name    = $m.Name
            type    = $m.Type
            base    = $m.Base
            created = $m.Created
            files   = $m.Files.Count
            deleted = $m.Deleted.Count
            sizeText = Format-Size $m.Size
            applies = [bool]$chainIds[$m.Id]
            project = $m.Project
        }
    }
    [pscustomobject]@{
        current   = $applied.lastId
        updatedAt = $applied.updatedAt
        chain     = @($res.Chain | ForEach-Object { $_.Id })
        notes     = @($res.Notes)
        packages  = $out
    }
}

function Get-ProjectHistory {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Project)
    $Paths = Get-ProjectPaths -Config $Config -Project $Project
    if (-not (Test-Path -LiteralPath $Paths.AppliedFile -PathType Leaf)) { return @() }
    $a = Get-AppliedState -Path $Paths.AppliedFile
    @($a.applied)
}

#endregion

#region ───────────────────────── 转移（导出 / 导入转移包） ─────────────────────────

function Get-Exports {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    try {
        $o = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($o.PSObject.Properties['exports'] -and $o.exports) { return @($o.exports) }
        return @()
    }
    catch { return @() }
}

function Add-ExportRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Record)
    $all = @(Get-Exports -Path $Path) + $Record
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [IO.File]::WriteAllText($Path, (([pscustomobject]@{ exports = $all }) | ConvertTo-Json -Depth 8), $script:Utf8NoBom)
}

function Get-ExportedIds {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Path)
    $set = @{}
    foreach ($r in @(Get-Exports -Path $Path)) {
        foreach ($id in @($r.packages)) { if ($id) { $set[[string]$id] = $true } }
    }
    $set
}

function Get-DriveList {
    <# 列出可用盘符（界面里选 U 盘/移动硬盘用）。#>
    [CmdletBinding()] param()
    $out = @()
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        $label = ''
        $free = -1; $total = -1
        try { if ($d.IsReady) { $free = $d.AvailableFreeSpace; $total = $d.TotalSize } } catch { }
        try { $label = $d.VolumeLabel } catch { }
        $out += [pscustomobject]@{
            path     = $d.Name
            driveType= $d.DriveType.ToString()
            label    = $label
            ready    = [bool]$d.IsReady
            freeBytes= $free
            freeText = $(if ($free -ge 0) { Format-Size $free } else { '-' })
            totalText= $(if ($total -ge 0) { Format-Size $total } else { '-' })
            removable= ($d.DriveType -eq [IO.DriveType]::Removable)
        }
    }
    $out
}

function New-TransferBundle {
    <#
      把一个项目的包打成「转移包」：单文件 zip（默认）或一个可直接运行的目录。
      转移包里自带还原脚本与说明，目标机解压后双击即可还原，不需要预装本工具。

      -Include new  只导出尚未导出过的包（默认，避免每次搬一大堆）
      -Include all  导出全部现存包
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$Project,
        [Parameter(Mandatory)][string]$Dest,
        [ValidateSet('new', 'all')][string]$Include = 'new',
        [ValidateSet('zip', 'folder')][string]$Format = 'zip',
        [int]$SplitMB = 0,             # >0 时把 zip 切成多个分卷
        [string]$LogFile
    )
    if ($LogFile) { Set-SyncLogFile -Path $LogFile }
    $Paths = Get-ProjectPaths -Config $Config -Project $Project
    Initialize-ProjectDirs -Paths $Paths

    $destRoot = Resolve-AnyPath -Path $Dest
    if (-not (Test-Path -LiteralPath $destRoot -PathType Container)) {
        try { New-Item -ItemType Directory -Force -Path $destRoot | Out-Null }
        catch { throw ("目标位置不可用：{0}" -f $destRoot) }
    }

    # ---------- 选包 ----------
    $allMetas = @(Get-PackageList -Dir $Paths.IncrementsDir | Sort-Object -Property @{ Expression = { Get-PackageIdTimestamp -Id $_.Id } })
    if ($allMetas.Count -eq 0) { throw '没有可导出的包，请先执行一次备份。' }
    $exported = Get-ExportedIds -Path $Paths.ExportsFile
    $pick = $allMetas
    if ($Include -eq 'new') {
        $pick = @($allMetas | Where-Object { -not $exported.ContainsKey($_.Id) })
        if ($pick.Count -eq 0) {
            Write-Log -Message '没有新的包需要导出（全部已导出过）。如需再次完整导出，请选择「导出全部」。' -Level 'OK'
            return $null
        }
        # 增量包必须能接上「已导出链」或自身是链头：这里用保底策略——如果本批含增量包，
        # 而链头不在本批内，就自动把最近的一个全量包一起带上，保证目标机能解开链。
        if (-not ($pick | Where-Object { $_.Type -eq 'full' })) {
            $head = @($allMetas | Where-Object { $_.Type -eq 'full' } | Select-Object -Last 1)
            if ($head.Count -gt 0 -and -not ($pick | Where-Object { $_.Id -eq $head[0].Id })) {
                $pick = @($head) + $pick
                Write-Log -Message ("本批不含链头，自动补上最近的全量包 {0}" -f $head[0].Id) -Level 'WARN'
            }
        }
    }
    if ($pick.Count -eq 0) { throw '没有可导出的包。' }

    $stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
    $bundle  = 'sync-{0}-{1}' -f $Project.id, $stamp
    $stageRoot = Join-Path $env:TEMP ('synckit-bundle-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $stage   = Join-Path $stageRoot $bundle
    $toolDir = Join-Path $stage 'sync-tool'
    New-Item -ItemType Directory -Force -Path (Join-Path $stage 'packages'), (Join-Path $toolDir 'bin'), (Join-Path $toolDir 'lib') | Out-Null

    $root = Get-SyncToolRoot
    $pickBytes = [long]0
    foreach ($x in @($pick)) { $pickBytes += [long]$x.Size }
    Write-Log -Message ("准备转移包：{0} 个包，{1}" -f $pick.Count, (Format-Size $pickBytes)) -Level 'STEP'

    $pkgInfo = @()
    $idx = 0
    foreach ($m in $pick) {
        $idx++
        $sha = Get-Sha256 -Path $m.ZipPath
        Copy-Item -LiteralPath $m.ZipPath -Destination (Join-Path $stage 'packages') -Force
        $pkgInfo += [pscustomobject]@{
            id     = $m.Id
            name   = $m.Name
            type   = $m.Type
            base   = $m.Base
            created= $m.Created
            files  = $m.Files.Count
            size   = $m.Size
            sha256 = $sha
        }
        Write-Log -Message ("  [{0}/{1}] {2}（{3}）" -f $idx, $pick.Count, $m.Name, (Format-Size $m.Size)) -Level 'INFO'
    }

    # ---------- 工具侧文件 ----------
    Copy-Item -LiteralPath (Join-Path $root 'lib\SyncKit.psm1') -Destination (Join-Path $toolDir 'lib') -Force
    foreach ($s in @('restore.ps1', 'backup.ps1', 'transfer.ps1')) {
        $p = Join-Path $root ('bin\' + $s)
        if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination (Join-Path $toolDir 'bin') -Force }
    }

    # ---------- 目标机的配置：dataRoot 落在转移包内，target 用源端解析后的绝对路径 ----------
    $tCfg = [pscustomobject]@{
        version     = 2
        dataRoot    = '..\data'
        defaultKeep = 20
        projects    = @(
            [pscustomobject]@{
                id          = $Project.id
                name        = $Project.name
                source      = ''
                target      = [string]$Paths.Target
                exclude     = @()
                keep        = 0
                preCommand  = ''
                postCommand = ''
                note        = '由转移包生成：请把 target 改成本机要还原到的目录'
            }
        )
    }
    [IO.File]::WriteAllText((Join-Path $toolDir 'projects.json'), ($tCfg | ConvertTo-Json -Depth 8), $script:Utf8NoBom)

    # ---------- bundle.json ----------
    $bjson = [pscustomobject]@{
        bundleVersion = 1
        toolVersion   = $script:SyncKitVersion
        projectId     = $Project.id
        projectName   = $Project.name
        created       = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
        host          = (Get-SyncHostName)
        sourceOnHost  = $Paths.Source
        targetHint    = [string]$Project.target
        packageCount  = $pkgInfo.Count
        packages      = $pkgInfo
    }
    [IO.File]::WriteAllText((Join-Path $stage 'bundle.json'), ($bjson | ConvertTo-Json -Depth 8), $script:Utf8NoBom)
    Write-ToolShaManifest -Stage $stage -PkgInfo $pkgInfo -Project $Project -Paths $Paths

    # ---------- 还原入口 bat ----------
    $bat = @(
        '@echo off'
        'chcp 65001 >nul'
        'setlocal'
        'rem ============================================================'
        'rem  SyncKit 转移包 —— 双击本文件即可把包还原到本机'
        'rem  说明：'
        'rem    1) 首次使用：先编辑 sync-tool\projects.json，把 target 改成要还原到的目录'
        'rem    2) 之后每次把新的转移包解压到本目录（覆盖同名文件）再双击本文件'
        'rem ============================================================'
        'powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync-tool\bin\restore.ps1" -Bundle "%~dp0" %*'
        'set RC=%ERRORLEVEL%'
        'echo.'
        'if "%RC%"=="0" (echo [OK] 完成) else (echo [FAIL] 退出码 %RC%，请看上方输出)'
        'pause'
    ) -join "`r`n"
    [IO.File]::WriteAllText((Join-Path $stage 'restore.bat'), $bat, $script:Utf8NoBom)

    # ---------- 说明.txt ----------
    $readme = @(
        'SyncKit 转移包'
        '=============================================================='
        ('项目      ：{0}（{1}）' -f $Project.name, $Project.id)
        ('包数量    ：{0} 个，合计 {1}' -f $pick.Count, (Format-Size $pickBytes))
        ('生成时间  ：{0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
        ('生成主机  ：{0}' -f (Get-SyncHostName))
        ('源目录    ：{0}' -f $Paths.Source)
        ''
        '【怎么用】'
        '  1. 把本转移包（zip）拷到目标电脑的固定目录（例如 D:\备份同步\）并解压。'
        '     之后每次都解压到同一个目录（同名文件覆盖）即可，进度会累积。'
        '  2. 打开 sync-tool\projects.json，把 "target" 改成目标电脑要还原到的目录。'
        '  3. 双击 restore.bat，等待完成。'
        ''
        '  想先看看会做什么而不实际写入：'
        '      双击 restore.bat 时带上 -Plan 参数，或命令行执行'
        '      powershell -File sync-tool\bin\restore.ps1 -Bundle . -Plan'
        ''
        '【安全机制】'
        '  · 包按 base 链校验，缺中间包 / 乱序会明确提示，不会应用错。'
        '  · 先整包解压校验 SHA256，全部通过才写入，拷贝损坏不会造成半新半旧。'
        '  · 还原操作可安全重复执行。'
        '  · 全量包会做镜像清理（删除不在全量包清单内的文件），可用来彻底对齐。'
        ''
        '【包清单】'
    )
    foreach ($p in $pkgInfo) {
        $readme += ('  {0}  {1}  {2}  {3}  sha256={4}' -f $p.created, $(if ($p.type -eq 'full') { '全量' } else { '增量' }), $p.name, (Format-Size $p.size), $p.sha256)
    }
    $readme += ''
    $readme += '【完整性校验】'
    $readme += '  sha256.txt 里是每个文件的 SHA256。命令行可用：'
    $readme += '      certutil -hashfile <文件> SHA256'
    [IO.File]::WriteAllText((Join-Path $stage '说明.txt'), ($readme -join "`r`n"), (New-Object Text.UTF8Encoding($true)))

    # ---------- 产出 ----------
    $result = $null
    $zipPath = Join-Path $destRoot ($bundle + '.zip')
    if ($Format -eq 'zip') {
        Remove-FileQuiet -Path $zipPath | Out-Null
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        [IO.Compression.ZipFile]::CreateFromDirectory($stage, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $false)
        $zipSha = Get-Sha256 -Path $zipPath
        [IO.File]::WriteAllText($zipPath + '.sha256', ($zipSha + '  ' + $bundle + '.zip' + "`r`n"), $script:Utf8NoBom)
        Write-Log -Message ("转移包已生成：{0}（{1}）" -f $zipPath, (Format-Size (Get-Item -LiteralPath $zipPath).Length)) -Level 'OK'
        Write-Log -Message ("转移包 SHA256：{0}" -f $zipSha) -Level 'INFO'
        $result = $zipPath

        if ($SplitMB -gt 0) {
            $parts = @(Split-FileToParts -Path $zipPath -SizeMB $SplitMB)
            Write-Log -Message ("已拆分为 {0} 个分卷，目标机请先运行 join-parts.bat 合并回 zip。" -f $parts.Count) -Level 'OK'
            $result = $parts
        }
    }
    else {
        $finalDir = Join-Path $destRoot $bundle
        Remove-PathQuiet -Path $finalDir
        Move-Item -LiteralPath $stage -Destination $finalDir
        $stage = $null
        Write-Log -Message ("转移目录已生成：{0}" -f $finalDir) -Level 'OK'
        $result = $finalDir
    }
    # folder 格式下 $stage 已被 Move-Item 搬走并置为 $null，这里只清掉空掉的 stageRoot
    if ($stage) { Remove-PathQuiet -Path $stage }
    Remove-PathQuiet -Path $stageRoot

    # ---------- 记录已导出 ----------
    Add-ExportRecord -Path $Paths.ExportsFile -Record ([pscustomobject]@{
        at       = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
        dest     = $destRoot
        format   = $Format
        packages = @($pkgInfo | ForEach-Object { $_.id })
        bundle   = $(if (Test-Path -LiteralPath $zipPath) { Split-Path -Leaf $zipPath } else { $bundle })
    })

    if ($Project.target -and -not (Test-Path -LiteralPath $Paths.Target -PathType Container)) {
        Write-Log -Message ("提示：源端记录的目标目录 {0} 在本机不存在，已原样写入转移包，目标机可直接用。" -f $Paths.Target) -Level 'INFO'
    }
    return $result
}

function Write-ToolShaManifest {
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Stage, [Parameter(Mandatory)]$PkgInfo, $Project, $Paths)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($f in @(Get-ChildItem -LiteralPath $Stage -Recurse -File | Sort-Object FullName)) {
        $rel = $f.FullName.Substring($Stage.TrimEnd('\').Length + 1).Replace('\', '/')
        $lines.Add(('{0}  {1}' -f (Get-Sha256 -Path $f.FullName), $rel))
    }
    [IO.File]::WriteAllText((Join-Path $Stage 'sha256.txt'), (($lines -join "`r`n") + "`r`n"), $script:Utf8NoBom)
}

function Split-FileToParts {
    <# 把大文件切成多个分卷，并生成 join-parts.bat（copy /b 合并）。#>
    [CmdletBinding()] param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][int]$SizeMB)
    $chunk = [long]$SizeMB * 1MB
    $dir = Split-Path -Parent $Path
    $base = Split-Path -Leaf $Path
    $parts = New-Object System.Collections.Generic.List[string]
    $in = [IO.File]::OpenRead($Path)
    try {
        $buf = New-Object byte[] (1MB)
        $i = 0
        while ($in.Position -lt $in.Length) {
            $i++
            $partName = '{0}.part{1:d3}' -f $base, $i
            $partPath = Join-Path $dir $partName
            $out = [IO.File]::Create($partPath)
            try {
                $written = [long]0
                while ($written -lt $chunk -and $in.Position -lt $in.Length) {
                    $want = [int][Math]::Min($buf.Length, $chunk - $written)
                    $read = $in.Read($buf, 0, $want)
                    if ($read -le 0) { break }
                    $out.Write($buf, 0, $read)
                    $written += $read
                }
            }
            finally { $out.Dispose() }
            $parts.Add($partPath)
        }
    }
    finally { $in.Dispose() }

    $bat = New-Object System.Collections.Generic.List[string]
    $bat.Add('@echo off')
    $bat.Add('chcp 65001 >nul')
    $bat.Add('cd /d "%~dp0"')
    $copyArgs = (@($parts | ForEach-Object { '"' + (Split-Path -Leaf $_) + '"' }) -join '+')
    $bat.Add(('copy /b {0} "{1}"' -f $copyArgs, $base))
    $bat.Add('if errorlevel 1 (echo 合并失败) else (echo 已合并为 ' + $base + '，可解压使用)')
    $bat.Add('pause')
    [IO.File]::WriteAllText((Join-Path $dir 'join-parts.bat'), ($bat -join "`r`n"), $script:Utf8NoBom)
    Remove-FileQuiet -Path $Path | Out-Null
    return $parts
}

function Import-TransferBundle {
    <#
      把转移包里的包导入到本机工具对应项目的 inbox（供界面/命令行使用）。
      会自动校验每个包的 SHA256，并记录导入来源。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$BundlePath,
        [string]$ProjectId = '',
        [switch]$NoApply,
        [string]$LogFile
    )
    if ($LogFile) { Set-SyncLogFile -Path $LogFile }
    $src = Resolve-AnyPath -Path $BundlePath
    $tmpExtract = $null

    if (-not (Test-Path -LiteralPath $src)) { throw ("找不到转移包：{0}" -f $src) }

    if ((Get-Item -LiteralPath $src).PSObject.Properties['PSIsContainer'] -and (Get-Item -LiteralPath $src).PSIsContainer) {
        $root = $src
    }
    elseif ($src -match '\.zip$') {
        $tmpExtract = Join-Path $env:TEMP ('synckit-import-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Force -Path $tmpExtract | Out-Null
        Write-Log -Message ("解压转移包：{0}" -f $src) -Level 'STEP'
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        [IO.Compression.ZipFile]::ExtractToDirectory($src, $tmpExtract)
        $inner = @(Get-ChildItem -LiteralPath $tmpExtract -Directory)
        if ($inner.Count -eq 1 -and (Test-Path -LiteralPath (Join-Path $inner[0].FullName 'bundle.json'))) {
            $root = $inner[0].FullName
        }
        else { $root = $tmpExtract }
    }
    elseif ($src -match '\.part\d{3}$') {
        throw '这是分卷文件，请先运行同目录的 join-parts.bat 合并成完整 zip 再导入。'
    }
    else { throw ("无法识别的转移包：{0}" -f $src) }

    try {
        $bjsonPath = Join-Path $root 'bundle.json'
        if (-not (Test-Path -LiteralPath $bjsonPath -PathType Leaf)) { throw ("不是有效的转移包（缺少 bundle.json）：{0}" -f $root) }
        $b = [IO.File]::ReadAllText($bjsonPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $pid2 = if ($ProjectId) { $ProjectId } else { [string]$b.projectId }
        if (-not $pid2) { throw '转移包里没有项目 ID，请用 -ProjectId 指定。' }
        $Project = Get-SyncProject -Config $Config -Id $pid2
        $Paths = Get-ProjectPaths -Config $Config -Project $Project

        Write-Log -Message ("转移包：{0}（{1}，生成于 {2} @{3}）" -f $b.projectName, $b.projectId, $b.created, $b.host) -Level 'STEP'
        $pkgDir = Join-Path $root 'packages'
        if (-not (Test-Path -LiteralPath $pkgDir -PathType Container)) { throw '转移包里没有 packages 目录。' }
        if (-not (Test-Path -LiteralPath $Paths.InboxDir)) { New-Item -ItemType Directory -Force -Path $Paths.InboxDir | Out-Null }

        $ok = 0; $bad = 0; $skip = 0
        foreach ($p in @($b.packages)) {
            $file = Join-Path $pkgDir ([string]$p.name)
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
                Write-Log -Message ("转移包内缺少 {0}" -f $p.name) -Level 'ERROR'; $bad++
                continue
            }
            $sha = Get-Sha256 -Path $file
            if ($p.sha256 -and $sha -ne $p.sha256) {
                Write-Log -Message ("SHA256 不匹配（文件可能损坏）：{0}" -f $p.name) -Level 'ERROR'
                $bad++
                continue
            }
            $dst = Join-Path $Paths.InboxDir ([string]$p.name)
            if (Test-Path -LiteralPath $dst) { $skip++ }
            else { Copy-Item -LiteralPath $file -Destination $dst -Force; $ok++ }
            $srcSha = Join-Path $pkgDir ([string]$p.name + '.sha256')
            if (Test-Path -LiteralPath $srcSha) { Copy-Item -LiteralPath $srcSha -Destination ($dst + '.sha256') -Force -ErrorAction SilentlyContinue }
        }
        Write-Log -Message ("导入完成：新增 {0}，已存在 {1}，校验失败 {2}" -f $ok, $skip, $bad) -Level 'OK'
        if ($bad -gt 0) { throw ("有 {0} 个包校验失败，请重新转移这些文件。" -f $bad) }

        Add-ExportRecord -Path $Paths.ExportsFile -Record ([pscustomobject]@{
            at       = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
            dest     = ('导入:' + $src)
            format   = 'import'
            packages = @($b.packages | ForEach-Object { $_.id })
            bundle   = $(if ($b.PSObject.Properties['bundle']) { $b.bundle } else { Split-Path -Leaf $src })
        })

        if (-not $NoApply) {
            Write-Log -Message '开始应用导入的包……' -Level 'STEP'
            return (Invoke-SyncRestore -Config $Config -Project $Project)
        }
        return 0
    }
    finally {
        Remove-PathQuiet -Path $tmpExtract
    }
}

#endregion

Export-ModuleMember -Function *
