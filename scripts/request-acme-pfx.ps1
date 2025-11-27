param(
    [Parameter(Mandatory = $true)][string[]]$Domains,
    [Parameter(Mandatory = $true)][string]$Email,
    [Parameter(Mandatory = $true)][string]$OutputPfx,
    [Parameter(Mandatory = $true)][string]$PfxPassword,
    [string]$StateDir = (Join-Path -Path $PSScriptRoot -ChildPath "..\\target\\acme-cache"),
    [string]$CaddyCommand = "caddy",
    [string]$AcmeServer = "https://acme-v02.api.letsencrypt.org/directory",
    [switch]$UseStaging,
    [int]$TimeoutSeconds = 600,
    [string]$DnsProvider,
    [string]$CloudflareApiToken
)

function Require-Command {
    param([string]$Name, [string]$InstallHint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' not found. $InstallHint"
    }
}

if ($Domains.Count -eq 0) {
    throw "Specify at least one domain."
}

if ($UseStaging) {
    $AcmeServer = "https://acme-staging-v02.api.letsencrypt.org/directory"
}

Require-Command -Name $CaddyCommand -InstallHint "Install Caddy from https://caddyserver.com/download."

$primaryDomain = $Domains[0]
$stateFull = (Resolve-Path -LiteralPath (New-Item -Path $StateDir -ItemType Directory -Force)).Path
$outputDir = Split-Path -Path $OutputPfx -Parent
if (-not $outputDir -or $outputDir -eq "") {
    $outputDir = (Get-Location).Path
}
if (-not (Test-Path $outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}
$outputFull = (Resolve-Path -LiteralPath $outputDir).Path
$OutputPfx = Join-Path -Path $outputFull -ChildPath (Split-Path -Leaf $OutputPfx)

$caddyfilePath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("daktilo-acme-" + [guid]::NewGuid().ToString() + ".Caddyfile")

$acmeUri = [Uri]$AcmeServer
$acmeStorageSegment = $acmeUri.Host
if ($acmeUri.AbsolutePath -and $acmeUri.AbsolutePath.Trim('/') -ne "") {
    $acmeStorageSegment += "-" + ($acmeUri.AbsolutePath.Trim('/').Replace("/", "-"))
}

$globalBlock = @(
    "{"
    "    email $Email"
    "    acme_ca $AcmeServer"
    "    storage file `"$stateFull`""
    "}"
) -join [Environment]::NewLine

$siteBlocks = @()
foreach ($domain in $Domains) {
    $block = "$domain {" + [Environment]::NewLine
    if ($DnsProvider) {
        $block += "    tls {" + [Environment]::NewLine
        $block += "        dns $DnsProvider" + [Environment]::NewLine
        if ($DnsProvider -ieq "cloudflare") {
            if (-not $CloudflareApiToken) {
                throw "Provide -CloudflareApiToken when using the Cloudflare DNS provider."
            }
            $env:CLOUDFLARE_API_TOKEN = $CloudflareApiToken
            $block += "        token {env.CLOUDFLARE_API_TOKEN}" + [Environment]::NewLine
        }
        $block += "    }" + [Environment]::NewLine
    }
    $block += "    respond 200 `"daktilo tray ACME bootstrap`"" + [Environment]::NewLine
    $block += "}" + [Environment]::NewLine
    $siteBlocks += $block
}

$caddyfileContent = $globalBlock + [Environment]::NewLine + ($siteBlocks -join [Environment]::NewLine)
Set-Content -LiteralPath $caddyfilePath -Value $caddyfileContent -Encoding UTF8

$arguments = @("run", "--config", $caddyfilePath, "--adapter", "caddyfile")
$startInfo = New-Object System.Diagnostics.ProcessStartInfo
$startInfo.FileName = $CaddyCommand
$startInfo.Arguments = [string]::Join(" ", $arguments)
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$process = New-Object System.Diagnostics.Process
$process.StartInfo = $startInfo
Write-Host "Launching Caddy to satisfy ACME challenges for $($Domains -join ', ')"
$process.Start() | Out-Null

$certDir = Join-Path -Path $stateFull -ChildPath ("certificates\" + $acmeStorageSegment + "\" + $primaryDomain)
$certPem = Join-Path -Path $certDir -ChildPath ($primaryDomain + ".crt")
$keyPem = Join-Path -Path $certDir -ChildPath ($primaryDomain + ".key")

$stopwatch = [Diagnostics.Stopwatch]::StartNew()
try {
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if ($process.HasExited) {
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            throw "Caddy exited early. stdout:`n$stdout`n`nstderr:`n$stderr"
        }
        if ((Test-Path $certPem) -and (Test-Path $keyPem)) {
            break
        }
        Start-Sleep -Seconds 3
    }

    if (-not (Test-Path $certPem)) {
        throw "Timed out waiting for ACME certificates. Check DNS routing to this host."
    }

    Write-Host "Certificates stored at $certDir. Exporting to $OutputPfx"
    $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPemFile($certPem, $keyPem)
    $pfxBytes = $certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Pfx, $PfxPassword)
    [System.IO.File]::WriteAllBytes($OutputPfx, $pfxBytes)
    Write-Host "PFX exported to $OutputPfx"
}
finally {
    if ($process -and -not $process.HasExited) {
        $process.CloseMainWindow() | Out-Null
        Start-Sleep -Seconds 2
        if (-not $process.HasExited) {
            $process.Kill()
        }
    }
    if (Test-Path $caddyfilePath) {
        Remove-Item -LiteralPath $caddyfilePath -Force
    }
}
