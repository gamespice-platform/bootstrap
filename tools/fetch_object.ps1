# One object of a content lock, hash-checked (gs-source it; needs $bases, the list of CDN bases, and tools\gs_download.ps1 loaded).
#   Fetch <rel> <dest> <sha> [<lock entry>] [<progress>]   to <dest> through <dest>.part, 4 tries over the bases
# Shared by tools\fetch_lock.ps1 and by each of its parallel download runspaces, so every file goes through the same checks.
# Windows PowerShell 5.1 and pwsh 7.
function Get-Sha([string]$p) { (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash.ToLower() }

function Test-Gzip([string]$p) {
    $fs = [IO.File]::OpenRead($p)
    try { $h = New-Object byte[] 2; ($fs.Read($h, 0, 2) -eq 2) -and $h[0] -eq 0x1f -and $h[1] -eq 0x8b } finally { $fs.Dispose() }
}
function Expand-Gzip([string]$p) {
    $tmp = "$p.gunzip"
    $in = [IO.File]::OpenRead($p); $out = [IO.File]::Create($tmp)
    try { $gz = New-Object IO.Compression.GZipStream($in, [IO.Compression.CompressionMode]::Decompress); $gz.CopyTo($out); $gz.Dispose() }
    finally { $out.Dispose(); $in.Dispose() }
    Move-Item -Force $tmp $p
}

# The manifest hash expected from base $b: the entry's manifest_sha256_by_origin[$b] when present, else manifest_sha256 (as fetch_lock.sh).
# Renamed CDN hosts, old=new, as fetch_lock.sh: $env:GS_ORIGIN_ALIASES replaces the list (space separated); empty turns it off.
$aliasList = if ($null -ne $env:GS_ORIGIN_ALIASES) { $env:GS_ORIGIN_ALIASES } else { 'https://dotgames.org=https://content.gamespice.net' }
$Aliases = @($aliasList -split '\s+' | Where-Object { $_ -match '=' } | ForEach-Object { , ($_ -split '=', 2) })
function Canon([string]$u) {
    $u = $u.TrimEnd('/')
    foreach ($a in $Aliases) {
        $old = $a[0].TrimEnd('/')
        if ($u -eq $old -or $u.StartsWith("$old/")) { return $a[1].TrimEnd('/') + $u.Substring($old.Length) }
    }
    $u
}
function Pin($p, [string]$b) {
    if ($p.manifest_sha256_by_origin) { foreach ($o in $p.manifest_sha256_by_origin.PSObject.Properties) { if ((Canon $o.Name) -eq (Canon $b)) { return $o.Value } } }
    $p.manifest_sha256
}

# One object to $dest through $dest.part, hash-checked; 4 tries over the bases. A part a broken connection left is
# resumed (Range), one that fails its hash is dropped. $prog: the pack's progress line (bytes and file i/n).
function Fetch([string]$rel, [string]$dest, [string]$sha, $entry = $null, $prog = $null) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    $part = "$dest.part"
    for ($i = 0; $i -lt 4; $i++) {
        $b = $bases[$i % $bases.Count]
        $sha = if ($entry) { Pin $entry $b } else { $sha }
        $before = if ($prog) { $prog.Done } else { 0 }
        try {
            if ($b -match '^[a-z]+://') { Invoke-GSDownload "$b/$rel" $part -Progress $prog -Resume }
            else {
                Copy-Item -LiteralPath (Join-Path $b $rel) $part -Force
                if ($prog) { $prog.Done += (Get-Item -LiteralPath $part).Length; Write-GSProgress $prog }
            }
            # The site stores some objects gzip-encoded and a CDN may send them as-is; the sha256 names the decoded bytes.
            if ((Get-Sha $part) -ne $sha -and (Test-Gzip $part)) { Expand-Gzip $part }
            if ((Get-Sha $part) -eq $sha) { Move-Item -Force $part $dest; return }
            Remove-Item -Force $part
            throw "hash mismatch for $b/$rel"
        } catch {
            if ($prog) { $prog.Done = $before }
            if ($i -eq 3) { throw }
            Write-Host "retry $b/$rel ($($_.Exception.Message))" -ForegroundColor DarkYellow
            Start-Sleep -Seconds ([math]::Pow(2, $i))
        }
    }
}
