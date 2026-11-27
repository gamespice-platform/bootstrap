# THE one fetcher on Windows: fetch exactly what a repo's content.lock.json names, hash-checked, once (present files skipped).
#   .\tools\fetch_lock.ps1 <content.lock.json> [-Root DIR] [-From BASE] [-Cdn URL] [-Cfg DIR] [-Except a,b] [-Only a,b] [-Packs DIR] [-Jobs N] [-List] [-TrustDevCa]
# -TrustDevCa ($env:GS_TRUST_DEV_CA=1): when the CDN is the dev one on the TMC local CA (https://x-tmc-storez) and Windows does not trust it, import
# <cdn>/tmc-local-ca.crt into Cert:\CurrentUser\Root (tools\gs_cdn.ps1); without it an interactive run asks first.
# Same behaviour as fetch_lock.sh, which documents the lock, the item names (id, name half, into, kind, repo; globs) and the cfg/content
# rules. Where from, first set wins: -From, $env:GS_PACKS_FROM ('none' fetches nothing), -Cdn / $env:GS_CDN_URL, GS_CDN_URL in
# -Jobs N / $env:GS_FETCH_JOBS (default 8): downloads in flight at once across all packs; 0 = unlimited, 1 = one file at a time as before.
# Every file is still hash-checked and a failed pack is named on the error stream (exit 1) while the others carry on.
# gs-bootstrap\.env, the lock's origin and mirrors, https://content.gamespice.net. (-Skip is the older name of -Except.)
param([Parameter(Mandatory)][string]$Lock, [string]$Root, [string]$From, [string]$Cdn, [string]$Cfg, [string]$Packs, [int]$Jobs = -1,
      [Alias('Skip')][string[]]$Except = @(), [string[]]$Only = @(), [switch]$List, [switch]$TrustDevCa)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # never PowerShell's progress bar (it slows 5.1 to a crawl); gs_download.ps1 prints our own
. (Join-Path $PSScriptRoot 'gs_download.ps1')
if (-not (Test-Path $Lock)) { Write-Host "fetch_lock: no $Lock, nothing pinned"; exit 0 }
$Lock = (Resolve-Path $Lock).Path
$lockDir = Split-Path -Parent $Lock
if (-not $Root) { $Root = $lockDir }
if (-not $From) { $From = $env:GS_PACKS_FROM }
if (-not $Cdn) { $Cdn = $env:GS_CDN_URL }
$envFile = Join-Path (Split-Path -Parent $PSScriptRoot) '.env'
$dotenv = @{}
if (Test-Path $envFile) { foreach ($l in Get-Content $envFile) { $l = $l.Trim(); if ($l -and -not $l.StartsWith('#') -and $l.Contains('=')) { $k, $v = $l.Split('=', 2); $dotenv[$k.Trim()] = $v.Trim().Trim('"', "'") } } }
if (-not $From -and -not $Cdn) { $Cdn = $dotenv['GS_CDN_URL'] }
if (-not $From -and -not $Cdn) { $From = $dotenv['GS_PACKS_FROM'] }
if ($Cdn -and -not $From) { $From = $Cdn.TrimEnd('/'); if ($From -match '^[a-z]+://' -and -not $From.EndsWith('/content')) { $From += '/content' } }
if ($From -match '^https://') { Initialize-GSCdnTrust $From -Trust:$TrustDevCa }
if ($From -eq 'none') { Write-Host 'fetch_lock: GS_PACKS_FROM=none, nothing fetched'; exit 0 }
$doc = Get-Content -Raw $Lock | ConvertFrom-Json
if ($doc.format -ne 1) { throw 'fetch_lock: unsupported lock format' }
$repo = Split-Path -Leaf $lockDir
if ($Packs) { New-Item -ItemType Directory -Force -Path $Packs | Out-Null; $Packs = (Resolve-Path $Packs).Path }
$bases = if ($From) { @($From) } elseif ($doc.origin) { @($doc.origin) + @($doc.mirrors) } else { @('https://content.gamespice.net/content') }
$bases = @($bases | ForEach-Object { $_.TrimEnd('/') })

. (Join-Path $PSScriptRoot 'fetch_object.ps1')

# The download lists: remove: entries, and the pack: entries of a list without merge: true (what fetch_lock.sh reads the same way).
if (-not $Cfg -and (Test-Path (Join-Path $lockDir 'cfg'))) { $Cfg = Join-Path $lockDir 'cfg' }
$removed = @(); $named = $null
function Id([string]$v) { ($v.Trim().Trim('"', "'") -split '@')[0] }
if ($Cfg) {
    foreach ($kind in 'addons', 'games') { foreach ($layer in 'content', 'server/content') {
        $f = Join-Path $Cfg "$layer/$kind.yml"; if (-not (Test-Path $f)) { continue }
        $merge = $false; $pk = @(); $key = ''
        foreach ($ln in Get-Content $f) {
            $ln = ($ln -split ' #')[0].TrimEnd(); $t = $ln.Trim()
            if (-not $t -or $t.StartsWith('#')) { continue }
            if ($ln -notmatch '^[ -]' -and $t.Contains(':')) {
                $k, $v = $t.Split(':', 2); $key = $k.Trim(); $v = $v.Trim()
                if ($key -eq 'merge') { $merge = ($v -eq 'true') }
                elseif ($v.StartsWith('[')) { foreach ($x in $v.Trim('[', ']').Split(',')) { if ($x.Trim()) { if ($key -eq 'remove') { $removed += Id $x } elseif ($key -eq 'entries' -and $x.Contains('/')) { $pk += Id $x } } } }
                continue
            }
            $t = $t.TrimStart('-').Trim()
            if ($t.Contains(':')) { $k, $v = $t.Split(':', 2); if ($key -eq 'entries' -and $k.Trim() -eq 'pack') { $pk += Id $v } }
            elseif ($key -eq 'remove') { $removed += Id $t }
            elseif ($key -eq 'entries' -and $t.Contains('/')) { $pk += Id $t }
        }
        if (-not $merge -and $pk.Count) { $named = $pk } elseif ($merge -and $pk.Count -and $null -ne $named) { $named += $pk }
    } }
}
function Hit($p, $pats) {
    $n = @($p.id, ($p.id -split '/')[-1], $p.into, $(if ($p.kind) { $p.kind } else { 'pack' }), $repo) | Where-Object { $_ }
    foreach ($g in $pats) { foreach ($x in $n) { if ($x -clike $g) { return $true } } }
    $false
}
function Why($p) {
    $half = ($p.id -split '/')[-1]; $kind = if ($p.kind) { $p.kind } else { 'pack' }
    if ($Only.Count -and -not (Hit $p $Only)) { return 'not in -Only' }
    if (Hit $p $Except) { return '-Except' }
    if (Hit $p $removed) { return 'removed in cfg/content' }
    if ($Cfg -and (Test-Path (Join-Path $Cfg "content/$half/disabled"))) { return "cfg/content/$half/disabled" }
    if ($null -ne $named -and $kind -eq 'pack' -and -not ((Hit $p $named) -or ($named | Where-Object { $p.id -clike $_ }))) { return 'not named in cfg/content' }
    ''
}

if ($Jobs -lt 0) { $Jobs = if ($env:GS_FETCH_JOBS -match '^\d+$') { [int]$env:GS_FETCH_JOBS } else { 8 } }
# .NET Framework allows 2 connections per host unless told otherwise, which would make every -Jobs above 2 a lie.
[Net.ServicePointManager]::DefaultConnectionLimit = if ($Jobs -gt 0) { [math]::Max($Jobs, 2) } else { 1000 }

# Phase 1, one pack at a time (small): decide what is needed and fetch the manifest. Phase 2: every missing file of every pack
# goes to one pool of -Jobs runspaces. Phase 3 (as each pack's last file lands): stamp it, or report it FAILED.
$bad = 0; $ctxs = @(); $queue = @()
foreach ($p in $doc.packs) {
    $kind = if ($p.kind) { $p.kind } else { 'pack' }
    $why = Why $p
    if ($List) { Write-Host ("{0} {1} {2} {3}" -f $(if ($why) { 'skip ' } else { 'fetch' }), $p.id, $p.version, $why); continue }
    if ($kind -eq 'pack' -and -not $Packs) { continue }
    if ($kind -ne 'store' -and $kind -ne 'pack') { continue }
    if ($why) { Write-Host "skip $($p.id) ($why)"; continue }
    $pre = "$($p.id)/$($p.version)"; $want = "$($p.id) $($p.version) $(Pin $p $bases[0])"
    $out = if ($kind -eq 'pack') { Join-Path $Packs $pre } else { Join-Path $Root $p.into }
    $stamp = Join-Path $out '.gs-pack'
    if ((Test-Path $stamp) -and ((Get-Content -Raw $stamp).Trim() -eq $want)) { Write-Host "have $($p.id) $($p.version)"; continue }
    try {
        $man = if ($kind -eq 'pack') { Join-Path $out 'manifest.json' } else { Join-Path $out '.manifest.json' }
        Fetch "$pre/manifest.json" $man '' $p
        $pad = (Get-Content -Raw $man | ConvertFrom-Json).payload.Replace('-', '+').Replace('_', '/')
        $pad += '=' * ((4 - $pad.Length % 4) % 4)
        $files = ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($pad)) | ConvertFrom-Json).files
        $seen = @{}
        $todo = @(foreach ($f in $files) {
            if ($f.path.StartsWith('/') -or ($f.path -split '/') -contains '..') { throw "unsafe path $($f.path)" }
            $obj = "$pre/objects/$($f.sha256.Substring(0,2))/$($f.sha256)"
            if ($kind -eq 'pack') { $dest = Join-Path $out "objects/$($f.sha256.Substring(0,2))/$($f.sha256)"; if ((Test-Path $dest) -or $seen[$dest]) { continue }; $seen[$dest] = $true }
            else { $dest = Join-Path $out $f.path; if ((Test-Path $dest) -and ((Get-Item $dest).Length -eq $f.size)) { continue } }
            [pscustomobject]@{ Obj = $obj; Dest = $dest; Sha = $f.sha256; Size = [long]$f.size }
        })
        $bytes = [long]0; foreach ($t in $todo) { $bytes += $t.Size }
        if ($todo.Count) {
            $already = if ($todo.Count -lt $files.Count) { ", $($files.Count - $todo.Count) already here" } else { '' }
            Write-Host ("fetching {0} {1}: {2} files, {3} MB{4}" -f $p.id, $p.version, $todo.Count, (Format-GSSize $bytes), $already)
        }
        $ctx = @{ P = $p; Kind = $kind; Want = $want; Stamp = $stamp; Man = $man; Count = $files.Count; Pending = $todo.Count
                  Failed = @(); Abort = [hashtable]::Synchronized(@{ Stop = $false }) }
        $ctxs += $ctx
        foreach ($t in $todo) { $queue += @{ Ctx = $ctx; T = $t } }
    } catch { Write-Host "FAILED $($p.id) $($p.version) $_" -ForegroundColor Red; $bad++ }
}

function Complete-Pack($ctx) {
    $p = $ctx.P
    if ($ctx.Failed.Count) {
        Write-Host "FAILED $($p.id) $($p.version) $($ctx.Failed[0])$(if ($ctx.Failed.Count -gt 1) { " (+$($ctx.Failed.Count - 1) more files)" })" -ForegroundColor Red
        return 1
    }
    Set-Content -NoNewline -Path $ctx.Stamp -Value "$($ctx.Want)`n"
    if ($ctx.Kind -eq 'store') { Remove-Item -Force $ctx.Man }
    Write-Host "fetched $($p.id) $($p.version) $($ctx.Count) files"
    0
}

if ($queue.Count) {
    $all = New-GSProgress 'content' (($queue | ForEach-Object { $_.T.Size } | Measure-Object -Sum).Sum) $queue.Count
    $workers = if ($Jobs -gt 0) { [math]::Min($Jobs, $queue.Count) } else { $queue.Count }
    $pool = [runspacefactory]::CreateRunspacePool(1, $workers); $pool.Open()
    # One file per runspace call: own progress object (one writer, never prints), the pack's Abort flag stops files still waiting.
    $worker = {
        param($tools, $bases, $rel, $dest, $sha, $prog, $abort)
        $ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
        if ($abort.Stop) { return }
        . (Join-Path $tools 'gs_download.ps1'); . (Join-Path $tools 'fetch_object.ps1')
        Fetch $rel $dest $sha $null $prog
    }
    foreach ($q in $queue) {
        $q.Prog = New-GSProgress $q.T.Obj $q.T.Size 0; $q.Prog.Next = [double]::MaxValue
        $q.PS = [powershell]::Create(); $q.PS.RunspacePool = $pool
        [void]$q.PS.AddScript($worker).AddArgument($PSScriptRoot).AddArgument($bases).AddArgument($q.T.Obj).AddArgument($q.T.Dest).AddArgument($q.T.Sha).AddArgument($q.Prog).AddArgument($q.Ctx.Abort)
        $q.H = $q.PS.BeginInvoke(); $q.Taken = $false
    }
    $left = $queue.Count; $finished = 0
    while ($left -gt 0) {
        foreach ($q in $queue) {
            if ($q.Taken -or -not $q.H.IsCompleted) { continue }
            $q.Taken = $true; $left--; $ctx = $q.Ctx
            try { [void]$q.PS.EndInvoke($q.H); if ($q.PS.HadErrors -and $q.PS.Streams.Error.Count) { throw $q.PS.Streams.Error[0].ToString() } }
            catch { $ctx.Failed += "$($q.T.Obj): $($_.Exception.Message)"; $ctx.Abort.Stop = $true }
            $q.PS.Dispose(); $ctx.Pending--
            if ($ctx.Pending -eq 0) { $bad += (Complete-Pack $ctx) }
        }
        $all.Done = [long]0; $fin = 0
        foreach ($q in $queue) { $all.Done += $q.Prog.Done; if ($q.Taken) { $fin++ } }
        $all.File = $fin
        Write-GSProgress $all
        if ($left -gt 0) { Start-Sleep -Milliseconds 200 }
    }
    Write-GSProgress $all -Final
    $pool.Close(); $pool.Dispose()
}
# A pack with nothing missing (stamp lost, files all present) is complete without any download.
foreach ($ctx in $ctxs) { if ($ctx.Pending -eq 0 -and -not $queue.Where({ $_.Ctx -eq $ctx }).Count) { $bad += (Complete-Pack $ctx) } }
exit ([int]($bad -gt 0))
