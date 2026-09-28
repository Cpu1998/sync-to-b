#Requires -Version 5.1
<#
.SYNOPSIS
    SyncKit 本地可视化界面：在浏览器里管理多个项目的备份 / 还原 / 转移。

.DESCRIPTION
    只监听本机回环地址（http://localhost:<端口>），不需要管理员权限、不需要联网。
    界面能力：
        · 多项目卡片：源目录、目标目录、快照文件数、包数量与占用、待应用数量
        · 一键增量备份 / 全量备份 / 差异预览
        · 包历史、收件箱、导出记录
        · 导出「转移包」到 U 盘或目录（可选分卷），或导入别人送来的转移包
        · 还原预演与应用
        · 实时日志输出（任务在独立进程中执行，界面不会被卡住）
        · 新建 / 编辑 / 删除项目（写回 projects.json）

.PARAMETER Port
    监听端口，默认 8787。被占用时自动往后找可用端口。

.PARAMETER NoBrowser
    启动后不自动打开浏览器。

.EXAMPLE
    .\bin\start-gui.ps1
    .\bin\start-gui.ps1 -Port 9000 -NoBrowser
#>
[CmdletBinding()]
param(
    [int]$Port = 8787,
    [switch]$NoBrowser,
    [string]$Config,
    [string]$LogFile
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $Root 'lib\SyncKit.psm1') -Force

if ($LogFile) { Set-SyncLogFile -Path $LogFile }
$script:WebRoot = Join-Path $Root 'web'
$script:Token   = [guid]::NewGuid().ToString('N')
$script:PowerShellExe = (Get-Process -Id $PID).Path
if (-not $script:PowerShellExe) { $script:PowerShellExe = 'powershell.exe' }

function Get-JobsRoot {
    try {
        $cfg = Get-SyncConfig -Path $Config
        $dataRoot = Resolve-AnyPath -Path ([string]$cfg.dataRoot) -Base $Root
    }
    catch { $dataRoot = Join-Path $Root 'data' }
    $d = Join-Path $dataRoot 'runtime\jobs'
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    $d
}
$script:JobsRoot = Get-JobsRoot
$script:JobRuns = @{}          # 任务 ID -> @{ PS; RS; Handle }（在服务进程内运行的 runspace）
$script:JobCancelled = @{}     # 任务 ID -> $true（被用户取消过）

#region ───────────── HTTP 基础 ─────────────

function Send-Bytes {
    param($Context, [byte[]]$Bytes, [string]$ContentType = 'application/octet-stream', [int]$Status = 200)
    try {
        $Context.Response.StatusCode = $Status
        $Context.Response.ContentType = $ContentType
        $Context.Response.ContentLength64 = $Bytes.Length
        $Context.Response.OutputStream.Write($Bytes, 0, $Bytes.Length)
    }
    catch { }
    finally { try { $Context.Response.Close() } catch { } }
}

function Send-Json {
    param($Context, $Data, [int]$Status = 200)
    $json = if ($Data -is [string]) { $Data } else { ConvertTo-Json -InputObject $Data -Depth 12 -Compress }
    Send-Bytes -Context $Context -Bytes ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json; charset=utf-8' -Status $Status
}

function Send-Text {
    param($Context, [string]$Text, [int]$Status = 200, [string]$ContentType = 'text/plain; charset=utf-8')
    Send-Bytes -Context $Context -Bytes ([Text.Encoding]::UTF8.GetBytes($Text)) -ContentType $ContentType -Status $Status
}

function Read-JsonBody {
    param($Context)
    if (-not $Context.Request.HasEntityBody) { return $null }
    $sr = New-Object IO.StreamReader($Context.Request.InputStream, [Text.Encoding]::UTF8)
    try { $txt = $sr.ReadToEnd() } finally { $sr.Dispose() }
    if ([string]::IsNullOrWhiteSpace($txt)) { return $null }
    try { return ($txt | ConvertFrom-Json) } catch { throw ('请求内容不是合法 JSON：' + $_.Exception.Message) }
}

function Get-Query {
    # 绝对不要用 $Context.Request.QueryString：HttpListenerRequest 自己那套解码链
    # 会把百分号转义按错误的方式还原，中文等非 ASCII 路径直接变乱码
    # （实测：客户端发 C:\测试\中文 目录，拿回来的是 C:\濞村鐦痋娑擃厽鏋?）。
    # 后果是 Test-Path 失败 → 目录选择器静默退回用户目录，表现成「点不进去」。
    # 这里改成读原始查询串（Uri.Query 保留 %XX），再用 [Uri]::UnescapeDataString
    # 按 UTF-8 还原，与前端 encodeURIComponent 完全对称。
    param($Context)
    $q = @{}
    $raw = ''
    try { $raw = [string]$Context.Request.Url.Query } catch { }
    if ($raw.StartsWith('?')) { $raw = $raw.Substring(1) }
    if (-not $raw) { return $q }
    foreach ($pair in $raw.Split('&')) {
        if (-not $pair) { continue }
        $i = $pair.IndexOf('=')
        if ($i -lt 0) { $k = $pair; $v = '' }
        else { $k = $pair.Substring(0, $i); $v = $pair.Substring($i + 1) }
        # 裸 + 按 HTML 表单编码约定还原成空格。这一步必须在解百分号「之前」做：
        # 浏览器 encodeURIComponent 会把路径里真实存在的加号编成 %2B，
        # 那时 %2B 还没被解码、不会被这条规则误伤，解出来仍是 +。
        $k = $k.Replace('+', ' ')
        $v = $v.Replace('+', ' ')
        try { $k = [Uri]::UnescapeDataString($k) } catch { }
        try { $v = [Uri]::UnescapeDataString($v) } catch { }
        $q[$k] = $v
    }
    $q
}

#endregion

#region ───────────── 任务（子进程） ─────────────

function Sanitize-Arg {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    ($Value -replace '["\r\n]', '').Trim()
}

function ConvertTo-ArgPath {
    <# 命令行里的路径统一用正斜杠，避开 Windows 命令行反斜杠转义引号的坑。#>
    param([string]$Value)
    $v = Sanitize-Arg $Value
    if (-not $v) { return '' }
    $v -replace '\\', '/'
}

function Get-JobRecord {
    param([string]$Id)
    $f = Join-Path $script:JobsRoot ($Id + '.json')
    if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return $null }
    try { return ([IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { return $null }
}

function Get-RunningJob {
    param()
    $latest = @(Get-ChildItem -LiteralPath $script:JobsRoot -Filter '*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First 5)
    foreach ($f in $latest) {
        $st = Get-JobStatus -Id ($f.BaseName)
        if ($st -and $st.running) { return $st }
    }
    return $null
}

function Get-JobStatus {
    param([string]$Id)
    $rec = Get-JobRecord -Id $Id
    if (-not $rec) { return $null }

    # 界面里的日志正文：任务脚本自己会写 -LogFile，这里直接读它
    $body = ''
    if ($rec.log -and (Test-Path -LiteralPath $rec.log -PathType Leaf)) {
        try { $body = [IO.File]::ReadAllText($rec.log, [Text.Encoding]::UTF8) } catch { }
    }

    $exit = $null
    $m = [regex]::Match($body, '(?m)\[EXIT\]\s+(-?\d+)\s*$')
    if ($m.Success) { $exit = [int]$m.Groups[1].Value }

    # 运行状态：优先看内存里的 runspace 句柄；服务重启后回退到日志标记
    $running = $false
    $run = $null
    if ($script:JobRuns.ContainsKey($Id)) { $run = $script:JobRuns[$Id] }
    if ($null -eq $exit) {
        if ($run) { $running = -not $run.Handle.IsCompleted }
        if ($running) { $exit = $null }
        elseif ($script:JobCancelled.ContainsKey($Id)) { $exit = 130 }
        else { $exit = -1 }
    }
    if ($script:JobCancelled.ContainsKey($Id) -and -not $running) { $exit = 130 }

    $lines = @($body -split "`r?`n")
    if ($lines.Count -gt 600) { $lines = $lines[($lines.Count - 600)..($lines.Count - 1)] }
    $body = ($lines -join "`n")

    if ($script:JobCancelled.ContainsKey($Id)) {
        $body = $body.TrimEnd() + "`n（任务已被用户取消。已写入的文件不会回滚；备份与还原操作都可以安全重跑。）"
    }
    elseif ($null -ne $exit -and $exit -ne 0 -and [string]::IsNullOrWhiteSpace($body)) {
        $body = '（任务没有产生任何日志，退出码 ' + $exit + "）`n" +
                '可能原因：脚本参数错误、源目录/目标目录不可访问、或文件被占用。' + "`n" +
                '可在命令行里直接跑同一条命令（bin\backup.ps1 等）查看完整报错。'
    }

    # 收尾：任务已结束就释放 runspace，避免长时间运行的服务累积内存
    if ($run -and $run.Handle.IsCompleted) {
        try { $run.PS.Dispose() } catch { }
        try { $run.RS.Close() } catch { }
        $script:JobRuns.Remove($Id)
    }

    [pscustomobject]@{
        id      = $Id
        action  = [string]$rec.action
        project = [string]$rec.project
        title   = [string]$rec.title
        started = [string]$rec.started
        running = $running
        exit    = $exit
        log     = $body
    }
}
function Start-SyncJob {
    param([string]$Action, $Body)
    $running = Get-RunningJob
    if ($running) { throw ('已经有一个任务在运行（{0}），请等它结束或先取消。' -f $running.title) }

    $project = ''
    if ($Body -and $Body.PSObject.Properties['project']) { $project = Sanitize-Arg ([string]$Body.project) }

    $id    = 'job-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + (Get-Random -Minimum 1000 -Maximum 9999)
    $log   = Join-Path $script:JobsRoot ($id + '.log')

    $title = ''
    $scriptPath = ''
    $p = @{}
    foreach ($prop in $Body.PSObject.Properties) { $p[$prop.Name] = $prop.Value }
    $params = [ordered]@{}

    switch ($Action) {
        'backup' {
            $kind = if ($p['full']) { '全量备份' } else { '增量备份' }
            if ($p['dryRun']) { $kind = '差异预览' }
            if (-not $project) { $title = ('全部项目：{0}' -f $kind) } else { $title = ('{0}：{1}' -f $project, $kind) }
            $scriptPath = Join-Path $Root 'bin\backup.ps1'
            if ($project)     { $params['Project'] = $project }
            if ($p['full'])   { $params['Full'] = $true }
            if ($p['dryRun']) { $params['DryRun'] = $true }
            if ($p['noHook']) { $params['NoHook'] = $true }
            if ($p['target']) { $params['Target'] = (ConvertTo-ArgPath ([string]$p['target'])) }
        }
        'restore' {
            if (-not $project) { throw '请指定要还原的项目。' }
            $title = ('{0}：{1}' -f $project, $(if ($p['plan']) { '还原预演' } else { '应用还原' }))
            $scriptPath = Join-Path $Root 'bin\restore.ps1'
            $params['Project'] = $project
            if ($p['plan'])      { $params['Plan'] = $true }
            if ($p['force'])     { $params['Force'] = $true }
            if ($p['targetDir']) { $params['TargetDir'] = (ConvertTo-ArgPath ([string]$p['targetDir'])) }
        }
        'export' {
            if (-not $project) { throw '请指定要导出的项目。' }
            $dest = ConvertTo-ArgPath ([string]$p['dest'])
            if (-not $dest) { throw '请选择转移包的输出位置（U 盘或目录）。' }
            $title = ('{0}：导出转移包 → {1}' -f $project, $dest)
            $scriptPath = Join-Path $Root 'bin\transfer.ps1'
            $params['Action']  = 'export'
            $params['Project'] = $project
            $params['Dest']    = $dest
            $params['Include'] = $(if ($p['include']) { Sanitize-Arg ([string]$p['include']) } else { 'new' })
            $params['Format']  = $(if ($p['format'])  { Sanitize-Arg ([string]$p['format']) }  else { 'zip' })
            $split = 0
            if ($p['splitMB']) { [void][int]::TryParse(([string]$p['splitMB']), [ref]$split) }
            if ($split -gt 0) { $params['SplitMB'] = $split }
        }
        'import' {
            $bundle = ConvertTo-ArgPath ([string]$p['bundle'])
            if (-not $bundle) { throw '请选择要导入的转移包（zip 或目录）。' }
            $title = ('导入转移包：{0}' -f (Split-Path -Leaf $bundle))
            $scriptPath = Join-Path $Root 'bin\transfer.ps1'
            $params['Action'] = 'import'
            $params['Bundle'] = $bundle
            if ($project)    { $params['Project'] = $project }
            if ($p['apply']) { $params['Apply'] = $true }
        }
        default { throw ('不支持的任务类型：{0}' -f $Action) }
    }

    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw ('找不到脚本：{0}' -f $scriptPath) }
    $params['LogFile'] = $log
    $script:LastJobTitle = $title

    # ---------- 在服务进程内用 Runspace 异步执行 ----------
    # 说明：刻意不用「另起一个 powershell 进程」的方式。
    # 1) PS 5.1 的 Start-Process 在环境变量存在同名大小写重复时（例如同时有
    #    http_proxy 与 HTTP_PROXY）会抛「字典中的关键字已添加」而根本起不来；
    # 2) 直接 Process.Start 在受限环境下会被拦截；
    # 3) Runspace 方式可以直接拿到运行状态与取消能力，且不依赖任何外部程序。
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddCommand($scriptPath)
    foreach ($k in $params.Keys) {
        $v = $params[$k]
        if ($v -is [bool]) { [void]$ps.AddParameter($k, [bool]$v) } else { [void]$ps.AddParameter($k, [string]$v) }
    }
    try { $handle = $ps.BeginInvoke() }
    catch {
        try { $rs.Close() } catch { }
        throw ('无法启动任务：{0}' -f $_.Exception.Message)
    }

    $rec = [pscustomobject]@{
        id      = $id
        action  = $Action
        project = $project
        title   = $title
        started = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
        log     = $log
    }
    [IO.File]::WriteAllText((Join-Path $script:JobsRoot ($id + '.json')), ($rec | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    $script:JobRuns[$id] = [pscustomobject]@{ PS = $ps; RS = $rs; Handle = $handle }
    Write-Host ('  [任务] {0} 已启动' -f $title) -ForegroundColor Cyan
    return $id
}

#endregion

#region ───────────── 接口 ─────────────

function Get-StatePayload {
    $cfg = Get-SyncConfig -Path $Config
    $items = @()
    foreach ($p in @($cfg.projects)) {
        try { $items += Get-ProjectStatus -Config $cfg -Project $p }
        catch {
            $items += [pscustomobject]@{
                id = $p.id; name = $p.name; source = ''; target = ''; error = $_.Exception.Message
                packageCount = 0; inboxCount = 0; pendingCount = 0
            }
        }
    }
    $running = Get-RunningJob
    [pscustomobject]@{
        ok         = $true
        version    = Get-SyncKitVersion
        toolRoot   = $Root
        configPath = (Get-SyncConfigPath -Root $Root)
        dataRoot   = (Resolve-AnyPath -Path ([string]$cfg.dataRoot) -Base $Root)
        host       = (Get-SyncHostName)
        user       = $env:USERNAME
        port       = $Port
        jobsRoot   = $script:JobsRoot
        now        = [DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
        defaultKeep= [int]$cfg.defaultKeep
        projects   = @($items)
        runningJob = $running
    }
}

function Normalize-PathInput {
    <# 容错处理「用户直接粘贴进来的路径」：
       资源管理器的「复制文件地址」给的是带双引号的 "D:\某目录"，
       浏览器地址栏复制过来可能是 file:///D:/某目录，也可能是正斜杠写法。
       统一在这里清洗，浏览接口、项目保存、打开目录三个入口都能受益。 #>
    param([string]$Value)
    $s = [string]$Value
    if (-not $s) { return '' }
    $s = $s.Trim()
    if ($s.Length -ge 2) {
        $a = $s.Substring(0, 1)
        $b = $s.Substring($s.Length - 1, 1)
        if (($a -eq '"' -and $b -eq '"') -or ($a -eq "'" -and $b -eq "'")) {
            $s = $s.Substring(1, $s.Length - 2).Trim()
        }
    }
    if ($s -match '^file:/{2,3}') {
        $s = ($s -replace '^file:/{2,3}', '')
        try { $s = [Uri]::UnescapeDataString($s) } catch { }
    }
    $s = $s -replace '/', '\'
    return $s
}

function Save-ProjectFromBody {
    param($Body)
    $cfg = Get-SyncConfig -Path $Config
    $id = Sanitize-Arg ([string]$Body.id)
    if (-not $id) { throw '项目 ID 不能为空。' }
    if ($id -notmatch '^[A-Za-z0-9._-]{1,64}$') { throw '项目 ID 只能用字母、数字、点、下划线、短横线（1-64 位）。' }

    $name = Sanitize-Arg ([string]$Body.name); if (-not $name) { $name = $id }
    $src  = Normalize-PathInput (Sanitize-Arg ([string]$Body.source))
    $tgt  = Normalize-PathInput (Sanitize-Arg ([string]$Body.target))
    $keep = 0; if ($Body.keep) { [void][int]::TryParse(([string]$Body.keep), [ref]$keep) }
    $ex   = @()
    foreach ($e in @($Body.exclude)) { $v = Sanitize-Arg ([string]$e); if ($v) { $ex += $v } }

    $obj = [pscustomobject]@{
        id          = $id
        name        = $name
        source      = $src
        target      = $tgt
        exclude     = @($ex)
        keep        = $keep
        preCommand  = Sanitize-Arg ([string]$Body.preCommand)
        postCommand = Sanitize-Arg ([string]$Body.postCommand)
        note        = Sanitize-Arg ([string]$Body.note)
    }

    $list = @($cfg.projects)
    $found = $false
    $out = @()
    foreach ($p in $list) {
        if ($p.id -eq $id) { $out += $obj; $found = $true } else { $out += $p }
    }
    if (-not $found) { $out += $obj }
    $cfg.projects = @($out)
    Save-SyncConfig -Config $cfg -Path (Get-SyncConfigPath -Root $Root) | Out-Null
    [pscustomobject]@{ ok = $true; created = (-not $found); id = $id }
}

function Remove-ProjectById {
    param([string]$Id)
    $cfg = Get-SyncConfig -Path $Config
    $keep = @($cfg.projects | Where-Object { $_.id -ne $Id })
    if ($keep.Count -eq @($cfg.projects).Count) { throw ('找不到项目：{0}' -f $Id) }
    $cfg.projects = @($keep)
    Save-SyncConfig -Config $cfg -Path (Get-SyncConfigPath -Root $Root) | Out-Null
    [pscustomobject]@{ ok = $true }
}

function Get-BrowsePayload {
    param([string]$Path)
    $Path = Normalize-PathInput $Path
    $requested = [string]$Path
    $notice = ''
    if (-not $Path) { $Path = $env:USERPROFILE }
    $p = $Path
    if (-not (Test-Path -LiteralPath $p)) {
        $notice = ('找不到这个路径：{0}' -f $requested)
        $p = $env:USERPROFILE
    }
    elseif (Test-Path -LiteralPath $p -PathType Leaf) {
        # 允许直接粘贴「某个文件的完整路径」，自动跳到它所在目录
        $p = (Split-Path -Parent $p)
    }
    try { $p = (Resolve-Path -LiteralPath $p).Path } catch { }
    $dirs = @()
    try {
        foreach ($d in @(Get-ChildItem -LiteralPath $p -Directory -Force -ErrorAction SilentlyContinue | Sort-Object Name)) {
            if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $dirs += [pscustomobject]@{ name = $d.Name; path = $d.FullName; hasChildren = $true }
        }
    }
    catch { }
    $parent = $null
    try { $parent = (Split-Path -Parent $p) } catch { }
    [pscustomobject]@{
        path      = $p
        requested = $requested
        notice    = $notice
        parent    = $parent
        # 盘符字段必须带上 path / ready：前端是 .filter(d => d.ready) + d.path 渲染的，
        # 之前这里把这两个字段投影掉了，导致目录选择器左栏永远是空的。
        drives    = @(Get-DriveList | ForEach-Object { [pscustomobject]@{ path = $_.path; name = $_.path; label = $_.label; driveType = $_.driveType; ready = $_.ready; freeText = $_.freeText; removable = $_.removable } })
        dirs      = @($dirs)
    }
}

#endregion

#region ───────────── 主循环 ─────────────

# 每个候选端口都必须用「全新的」HttpListener 实例：
# HttpListener 一旦 Start() 失败就会进入不可用状态（Prefixes 变成 null），
# 复用同一个实例会让后面所有端口连带失败（报「不能对 Null 值表达式调用方法」）。
$started = $false
$listener = $null
$lastError = ''
$basePort = $Port
for ($i = 0; $i -lt 25; $i++) {
    $tryListener = New-Object System.Net.HttpListener
    $tryListener.IgnoreWriteExceptions = $true
    try {
        $tryListener.Prefixes.Add(('http://localhost:{0}/' -f $Port))
        $tryListener.Start()
        $listener = $tryListener
        $started = $true
        break
    }
    catch {
        $lastError = $_.Exception.GetBaseException().Message
        Write-Verbose ('端口 {0} 不可用：{1}' -f $Port, $lastError)
        try { $tryListener.Close() } catch { }
        $Port++
    }
}
if (-not $started) {
    $hint = '本机可能把该端口段保留给了系统（Docker / Hyper-V / WSL 常见），可用 netsh interface ipv4 show excludedportrange protocol=tcp 查看。'
    $msg = '无法启动本地服务：从 {0} 起的连续 25 个端口都不可用。最后一个端口 {1} 的错误：{2}  {3} 也可以换一段端口试试：.\start-gui.ps1 -Port 9000' -f $basePort, ($Port - 1), $lastError, $hint
    throw $msg
}

$url = 'http://localhost:{0}/' -f $Port
Write-Host ''
Write-Host '  SyncKit · 增量备份中心' -ForegroundColor Cyan
Write-Host ('  ────────────────────────────────────────')
Write-Host ('  本地界面：{0}' -f $url) -ForegroundColor Green
Write-Host ('  工具目录：{0}' -f $Root)
Write-Host ('  配置文件：{0}' -f (Get-SyncConfigPath -Root $Root))
Write-Host ('  任务日志：{0}' -f $script:JobsRoot)
Write-Host '  关闭本窗口即停止服务。' -ForegroundColor DarkGray
Write-Host ''

if (-not $NoBrowser) {
    try { Start-Process $url | Out-Null } catch { Write-Host '  （未能自动打开浏览器，请手动访问上面的地址）' -ForegroundColor Yellow }
}

$mimeMap = @{
    '.html' = 'text/html; charset=utf-8'
    '.js'   = 'application/javascript; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.svg'  = 'image/svg+xml'
    '.png'  = 'image/png'
    '.ico'  = 'image/x-icon'
    '.txt'  = 'text/plain; charset=utf-8'
}

try {
    while ($listener.IsListening) {
        $ctx = $null
        try { $ctx = $listener.GetContext() } catch { break }
        if (-not $ctx) { continue }

        $reqPath = $ctx.Request.Url.AbsolutePath
        $query   = Get-Query -Context $ctx
        $method  = $ctx.Request.HttpMethod

        try {
            # ---------- 静态资源 ----------
            if ($reqPath -eq '/' -or $reqPath -eq '/index.html') {
                $html = [IO.File]::ReadAllText((Join-Path $script:WebRoot 'index.html'), [Text.Encoding]::UTF8)
                $html = $html.Replace('__SYNC_TOKEN__', $script:Token).Replace('__SYNC_VERSION__', (Get-SyncKitVersion))
                Send-Text -Context $ctx -Text $html -ContentType 'text/html; charset=utf-8'
                continue
            }
            if ($reqPath -eq '/favicon.ico') { Send-Bytes -Context $ctx -Bytes (New-Object byte[] 0) -ContentType 'image/x-icon'; continue }

            if ($reqPath.StartsWith('/static/')) {
                $rel = $reqPath.Substring('/static/'.Length)
                $file = [IO.Path]::GetFullPath((Join-Path $script:WebRoot ($rel -replace '/', '\')))
                if (-not $file.StartsWith($script:WebRoot, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $file -PathType Leaf)) {
                    Send-Text -Context $ctx -Text 'not found' -Status 404
                    continue
                }
                $ext = [IO.Path]::GetExtension($file).ToLower()
                $ct = if ($mimeMap.ContainsKey($ext)) { $mimeMap[$ext] } else { 'application/octet-stream' }
                Send-Bytes -Context $ctx -Bytes ([IO.File]::ReadAllBytes($file)) -ContentType $ct
                continue
            }

            # ---------- 接口（需要令牌） ----------
            if (-not $reqPath.StartsWith('/api/')) { Send-Text -Context $ctx -Text 'not found' -Status 404; continue }

            # 注意：PowerShell 变量名不区分大小写，这里必须用 $reqToken。
            # 若写成 $token，会与脚本级的 $script:Token 同名并把令牌清空（已踩过的坑）。
            $reqToken = [string]$ctx.Request.Headers['X-Sync-Token']
            if (-not $reqToken) { $reqToken = [string]$query['token'] }
            if (-not $script:Token -or $reqToken -ne $script:Token) {
                Send-Json -Context $ctx -Data ([pscustomobject]@{ ok = $false; error = '令牌无效，请通过 bin\start-gui.ps1 启动的地址访问界面。' }) -Status 403
                continue
            }

            switch ($reqPath) {
                '/api/ping'   { Send-Json -Context $ctx -Data ([pscustomobject]@{ ok = $true; version = (Get-SyncKitVersion) }); continue }
                '/api/state'  { Send-Json -Context $ctx -Data (Get-StatePayload); continue }
                '/api/drives' { Send-Json -Context $ctx -Data ([pscustomobject]@{ ok = $true; drives = @(Get-DriveList) }); continue }
                '/api/browse' { Send-Json -Context $ctx -Data (Get-BrowsePayload -Path ([string]$query['path'])); continue }
                '/api/packages' {
                    $cfg = Get-SyncConfig -Path $Config
                    $proj = Get-SyncProject -Config $cfg -Id ([string]$query['project'])
                    Send-Json -Context $ctx -Data ([pscustomobject]@{ ok = $true; items = @(Get-ProjectPackages -Config $cfg -Project $proj) })
                    continue
                }
                '/api/exports' {
                    $cfg = Get-SyncConfig -Path $Config
                    $proj = Get-SyncProject -Config $cfg -Id ([string]$query['project'])
                    $Paths = Get-ProjectPaths -Config $cfg -Project $proj
                    Send-Json -Context $ctx -Data ([pscustomobject]@{ ok = $true; items = @(Get-Exports -Path $Paths.ExportsFile) })
                    continue
                }
                '/api/inbox' {
                    $cfg = Get-SyncConfig -Path $Config
                    $proj = Get-SyncProject -Config $cfg -Id ([string]$query['project'])
                    Send-Json -Context $ctx -Data ([pscustomobject]@{ ok = $true; inbox = (Get-ProjectInbox -Config $cfg -Project $proj) })
                    continue
                }
                '/api/job' {
                    $st = Get-JobStatus -Id ([string]$query['id'])
                    if (-not $st) { Send-Json -Context $ctx -Data ([pscustomobject]@{ ok = $false; error = '找不到该任务。' }) -Status 404 }
                    else { Send-Json -Context $ctx -Data ([pscustomobject]@{ ok = $true; job = $st }) }
                    continue
                }
                '/api/jobs' {
                    $items = @()
                    foreach ($f in @(Get-ChildItem -LiteralPath $script:JobsRoot -Filter '*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First 30)) {
                        $r = Get-JobRecord -Id $f.BaseName
                        if ($r) { $items += [pscustomobject]@{ id = $r.id; title = $r.title; action = $r.action; project = $r.project; started = $r.started } }
                    }
                    Send-Json -Context $ctx -Data ([pscustomobject]@{ ok = $true; items = @($items) })
                    continue
                }
                '/api/open' {
                    $folder = ConvertTo-ArgPath (Normalize-PathInput ([string]$query['path']))
                    if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { Send-Json -Context $ctx -Data ([pscustomobject]@{ ok = $false; error = '目录不存在。' }) -Status 400; continue }
                    Start-Process 'explorer.exe' -ArgumentList ('"' + ([IO.Path]::GetFullPath($folder)) + '"')
                    Send-Json -Context $ctx -Data ([pscustomobject]@{ ok = $true }); continue
                }

                '/api/run' {
                    if ($method -ne 'POST') { Send-Json -Context $ctx -Data ([pscustomobject]@{ ok = $false; error = '需要 POST。' }) -Status 405; continue }
                    $body = Read-JsonBody -Context $ctx
                    if (-not $body) { throw '请求内容为空。' }
                    $action = Sanitize-Arg ([string]$body.action)
                    $id = Start-SyncJob -Action $action -Body $body
                    Send-Json -Context $ctx -Data ([pscustomobject]@{ ok = $true; id = $id; title = $script:LastJobTitle })
                    continue
                }
                '/api/job/cancel' {
                    if ($method -ne 'POST') { Send-Json -Context $ctx -Data ([pscustomobject]@{ ok = $false; error = '需要 POST。' }) -Status 405; continue }
                    $body = Read-JsonBody -Context $ctx
                    $cancelId = Sanitize-Arg ([string]$body.id)
                    $rec = Get-JobRecord -Id $cancelId
                    if (-not $rec) { Send-Json -Context $ctx -Data ([pscustomobject]@{ ok = $false; error = '找不到该任务。' }) -Status 404; continue }
                    $script:JobCancelled[$cancelId] = $true
                    if ($script:JobRuns.ContainsKey($cancelId)) {
                        try { $script:JobRuns[$cancelId].PS.Stop() } catch { }
                        try { $script:JobRuns[$cancelId].RS.Close() } catch { }
                        $script:JobRuns.Remove($cancelId)
                    }
                    if ($rec.log) {
                        $mark = '{0} [WARN] 任务被用户取消（已写入的文件不会回滚，可安全重跑）。' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
                        try { [IO.File]::AppendAllText($rec.log, $mark + "`r`n", (New-Object Text.UTF8Encoding($false))) } catch { }
                    }
                    Send-Json -Context $ctx -Data ([pscustomobject]@{ ok = $true }); continue
                }
                '/api/project/save' {
                    if ($method -ne 'POST') { Send-Json -Context $ctx -Data ([pscustomobject]@{ ok = $false; error = '需要 POST。' }) -Status 405; continue }
                    $body = Read-JsonBody -Context $ctx
                    Send-Json -Context $ctx -Data (Save-ProjectFromBody -Body $body); continue
                }
                '/api/project/delete' {
                    if ($method -ne 'POST') { Send-Json -Context $ctx -Data ([pscustomobject]@{ ok = $false; error = '需要 POST。' }) -Status 405; continue }
                    $body = Read-JsonBody -Context $ctx
                    Send-Json -Context $ctx -Data (Remove-ProjectById -Id (Sanitize-Arg ([string]$body.id))); continue
                }
                default { Send-Json -Context $ctx -Data ([pscustomobject]@{ ok = $false; error = ('未知接口：' + $reqPath) }) -Status 404; continue }
            }
        }
        catch {
            try {
                Send-Json -Context $ctx -Data ([pscustomobject]@{
                    ok    = $false
                    error = $_.Exception.Message
                    at    = $_.ScriptStackTrace
                }) -Status 500
            } catch { }
        }
    }
}
finally {
    try { $listener.Stop() } catch { }
    try { $listener.Close() } catch { }
    Write-Host '  服务已停止。' -ForegroundColor DarkGray
}
#endregion
