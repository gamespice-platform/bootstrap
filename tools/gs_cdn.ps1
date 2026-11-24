# Which content CDN a run uses, and trusting the dev CDN's local CA on Windows (gs-source it; Windows PowerShell 5.1 and pwsh 7).
#   Get-GSCdnInfo [-Cdn url]        @{ Url; Source; Dev }   first set wins: -Cdn, $env:GS_PACKS_FROM, $env:GS_CDN_URL, GS_CDN_URL in
#                                   gs-bootstrap\.env, else https://content.gamespice.net (a lock's own origin applies per repo, later)
#   Write-GSCdnHeader [-Cdn url]    the `cdn:` line at the top of a run; DEV in capitals and a colour when it is not the prod default
#   Initialize-GSCdnTrust <url> [-Trust]   dev CDN on a private CA (https://x-tmc-storez): when the TLS handshake fails to trust it,
#                                   fetch <host>/tmc-local-ca.crt over plain http and, with -Trust ($env:GS_TRUST_DEV_CA=1) or a "y"
#                                   at the prompt, import it into Cert:\CurrentUser\Root (no admin; one Windows confirm dialog).
#                                   Windows PowerShell trusts the WINDOWS store, not a browser's (Brave/Chrome have their own).
$script:GSProdCdn = 'https://content.gamespice.net'

function Read-GSDotenv([string]$Key) {
    $envFile = Join-Path (Split-Path -Parent $PSScriptRoot) '.env'
    if (-not (Test-Path $envFile)) { return '' }
    foreach ($l in Get-Content $envFile) {
        $l = $l.Trim()
        if ($l -and -not $l.StartsWith('#') -and $l.Contains('=')) {
            $k, $v = $l.Split('=', 2)
            if ($k.Trim() -eq $Key) { return $v.Trim().Trim('"', "'") }
        }
    }
    ''
}

function Get-GSCdnInfo([string]$Cdn = '') {
    $src = ''
    if ($Cdn) { $src = '-Cdn' }
    elseif ($env:GS_PACKS_FROM) { $Cdn = $env:GS_PACKS_FROM; $src = '$GS_PACKS_FROM' }
    elseif ($env:GS_CDN_URL) { $Cdn = $env:GS_CDN_URL; $src = '$GS_CDN_URL' }
    else {
        $e = Read-GSDotenv 'GS_CDN_URL'
        if ($e) { $Cdn = $e; $src = '.env' } else { $e = Read-GSDotenv 'GS_PACKS_FROM'; if ($e) { $Cdn = $e; $src = '.env (GS_PACKS_FROM)' } }
    }
    if (-not $Cdn) { return [pscustomobject]@{ Url = $script:GSProdCdn; Source = 'default'; Dev = $false } }
    $u = $Cdn.TrimEnd('/') -replace '/content$', ''
    $prod = ($u -eq $script:GSProdCdn) -or ($u -eq 'https://dotgames.org')
    [pscustomobject]@{ Url = $u; Source = $src; Dev = (-not $prod) }
}

function Write-GSCdnHeader([string]$Cdn = '') {
    $i = Get-GSCdnInfo $Cdn
    if ($i.Dev) { Write-Host ("cdn:      {0}  (DEV, from {1})" -f $i.Url, $i.Source) -ForegroundColor Yellow }
    else { Write-Host ("cdn:      {0}  (prod, {1})" -f $i.Url, $i.Source) }
}

function Test-GSTlsTrustError($ex) {
    for ($e = $ex; $e; $e = $e.InnerException) {
        if ($e.Message -match 'SSL|TLS|trust relationship|certificate|secure channel|authentication failed') { return $true }
    }
    $false
}

function ConvertFrom-GSPem([byte[]]$Bytes) {
    $t = [Text.Encoding]::ASCII.GetString($Bytes)
    if ($t -notmatch '-----BEGIN CERTIFICATE-----([\s\S]+?)-----END CERTIFICATE-----') { return $null }
    [Convert]::FromBase64String(($Matches[1] -replace '\s', ''))
}

function Initialize-GSCdnTrust([string]$Url, [switch]$Trust) {
    if ($Url -notmatch '^https://([^/:]+)') { return }
    $hostName = $Matches[1]
    if ($Url -match 'content\.gamespice\.net|dotgames\.org') { return }
    if ($env:GS_TRUST_DEV_CA -eq '1') { $Trust = $true }
    $http = Get-GSHttp
    try { $r = $http.GetAsync("$($Url.TrimEnd('/'))/").Result; $r.Dispose(); return }   # any HTTP answer: the handshake is trusted
    catch { if (-not (Test-GSTlsTrustError $_.Exception)) { return } }                 # unreachable etc.: the download reports it
    $caUrl = if ($env:GS_CDN_CA_URL) { $env:GS_CDN_CA_URL } else { "http://$hostName/tmc-local-ca.crt" }
    $der = $null
    try {
        if ($env:GS_CDN_CA -and (Test-Path $env:GS_CDN_CA)) { $raw = [IO.File]::ReadAllBytes($env:GS_CDN_CA) }
        else { $raw = $http.GetByteArrayAsync($caUrl).Result }
        $der = ConvertFrom-GSPem $raw
    } catch { }
    $one = "Invoke-WebRequest $caUrl -OutFile `$env:TEMP\tmc-local-ca.crt; Import-Certificate -FilePath `$env:TEMP\tmc-local-ca.crt -CertStoreLocation Cert:\CurrentUser\Root"
    Write-Host "cdn:      $Url is signed by the TMC Local Development CA, which Windows does not trust yet." -ForegroundColor Yellow
    if (-not $der) { Write-Host "          could not fetch the CA from $caUrl. By hand: $one" -ForegroundColor Yellow; return }
    $cert = New-Object Security.Cryptography.X509Certificates.X509Certificate2(, $der)
    if ($cert.Subject -notmatch 'TMC Local Development CA') { Write-Host "          $caUrl is not the TMC Local Development CA ($($cert.Subject)); not importing." -ForegroundColor Red; return }
    if (-not $Trust -and [Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
        $a = Read-Host "          Trust it for your Windows user (Cert:\CurrentUser\Root, no admin, one confirm dialog)? [y/N]"
        if ($a -match '^[yY]') { $Trust = $true }
    }
    if (-not $Trust) { Write-Host "          Re-run with -TrustDevCa, or by hand: $one" -ForegroundColor Yellow; return }
    $file = Join-Path ([IO.Path]::GetTempPath()) 'tmc-local-ca.cer'
    [IO.File]::WriteAllBytes($file, $der)
    try { Import-Certificate -FilePath $file -CertStoreLocation Cert:\CurrentUser\Root -ErrorAction Stop | Out-Null; Write-Host "          imported $($cert.Thumbprint) into Cert:\CurrentUser\Root" -ForegroundColor Green }
    catch {
        & certutil.exe -user -addstore -f Root $file | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Host "          import failed ($_). By hand: $one   or   certutil -user -addstore Root `"$file`"" -ForegroundColor Red; return }
        Write-Host "          imported $($cert.Thumbprint) with certutil" -ForegroundColor Green
    }
    $script:GSHttp = $null   # a fresh client, so the next handshake reads the new store
}
