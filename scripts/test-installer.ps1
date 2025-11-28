[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ArtifactsDir,
    [string]$Channel = "stable",
    [string]$ConfigPath = "dist-workspace.toml",
    [int]$AutostartWaitSeconds = 30
)

. (Join-Path -Path $PSScriptRoot -ChildPath "common-dist.ps1")

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$logDir = Join-Path -Path $repoRoot -ChildPath "target/smoke-tests"
if (Test-Path $logDir) {
    Remove-Item -LiteralPath $logDir -Recurse -Force
}
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$installLog = Join-Path $logDir "msi-install.log"
$verifyLog = Join-Path $logDir "signtool-verify.log"
$summaryPath = Join-Path $logDir "summary.txt"
$reportPath = Join-Path $logDir "signtool-report.json"

function Write-Summary {
    param([string]$Message)
    $Message | Tee-Object -FilePath $summaryPath -Append | Out-Null
}

$metadata = $null
try {
    $metadata = Get-DistMetadata -Path $ConfigPath
} catch {
    Write-Warning $_.Exception.Message
}

$defaultAutostart = $false
if ($metadata -and $metadata.workspace -and
    $metadata.workspace.metadata -and
    $metadata.workspace.metadata.dist -and
    $metadata.workspace.metadata.dist.autostart -and
    $metadata.workspace.metadata.dist.autostart.default_enabled -ne $null) {
    $defaultAutostart = [bool]$metadata.workspace.metadata.dist.autostart.default_enabled
}
Write-Summary "Channel: $Channel"
Write-Summary "Expected autostart default: $defaultAutostart"

$codesignProfile = $null
$expectedSign = [ordered]@{
    subject       = $null
    thumbprint    = $null
    store         = $null
    store_location = $null
}
if ($metadata) {
    try {
        $codesignProfile = Get-CodesignProfile -Metadata $metadata -Channel $Channel
    } catch {
        Write-Warning "Failed to resolve codesign metadata: $($_.Exception.Message)"
    }
}
if ($codesignProfile -and $codesignProfile.Settings) {
    $settings = $codesignProfile.Settings
    if ($settings.subject) { $expectedSign.subject = $settings.subject }
    if ($settings.thumbprint) { $expectedSign.thumbprint = $settings.thumbprint }
    if ($settings.store) { $expectedSign.store = $settings.store }
    if ($settings.store_location) { $expectedSign.store_location = $settings.store_location }
    Write-Summary "Codesign channel metadata: $($codesignProfile.Name)"
    if ($expectedSign.subject) { Write-Summary "Expected subject: $($expectedSign.subject)" }
    if ($expectedSign.thumbprint) { Write-Summary "Expected thumbprint: $($expectedSign.thumbprint)" }
} else {
    Write-Summary "Codesign channel metadata not found for $Channel"
}

$msi = Get-ChildItem -Path $ArtifactsDir -Filter *.msi -Recurse | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $msi) {
    throw "No MSI found under $ArtifactsDir"
}
Write-Summary "Using MSI: $($msi.FullName)"

$installArgs = "/i `"$($msi.FullName)`" /qn /norestart /L*v `"$installLog`""
$install = Start-Process -FilePath "msiexec.exe" -ArgumentList $installArgs -PassThru -Wait
if ($install.ExitCode -ne 0) {
    throw "msiexec install failed with exit code $($install.ExitCode). See $installLog"
}

$programFiles = @()
if ($env:ProgramFiles) { $programFiles += $env:ProgramFiles }
if ($env:"ProgramFiles(x86)") { $programFiles += $env:"ProgramFiles(x86)" }
$exePath = $null
foreach ($root in $programFiles) {
    $candidate = Join-Path $root "daktilo-tray\bin\daktilo-tray.exe"
    if (Test-Path $candidate) {
        $exePath = $candidate
        break
    }
}
if (-not $exePath) {
    throw "Installed daktilo-tray.exe not found under Program Files"
}
Write-Summary "Resolved installed binary: $exePath"

$env:DAKTILO_AUTOSTART_ONLY = "1"
$process = Start-Process -FilePath $exePath -PassThru
try {
    if (-not $process.WaitForExit($AutostartWaitSeconds * 1000)) {
        $process.Kill()
        throw "Daktilo Tray did not exit autostart smoke mode within $AutostartWaitSeconds seconds"
    }
} finally {
    Remove-Item Env:DAKTILO_AUTOSTART_ONLY -ErrorAction SilentlyContinue
}
Write-Summary "Autostart smoke mode exited with code $($process.ExitCode)"

$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$appName = "Daktilo Tray"
$registryValue = $null
try {
    $registryValue = (Get-ItemProperty -Path $runKey -Name $appName -ErrorAction Stop)."$appName"
} catch {
    $registryValue = $null
}
$hasEntry = [bool]$registryValue
Write-Summary "Run key present: $hasEntry"
if ($defaultAutostart -and -not $hasEntry) {
    throw "Expected $appName to register under $runKey"
}
if (-not $defaultAutostart -and $hasEntry) {
    throw "Expected $appName to skip autostart registration when default_enabled = $defaultAutostart"
}

$signTool = Get-SignToolPath
Write-Summary "signtool: $signTool"
$verifyCommand = "`"$signTool`" verify /pa /v `"$($msi.FullName)`""
$verifyStarted = Get-Date
& $signTool verify /pa /v "$($msi.FullName)" 2>&1 | Tee-Object -FilePath $verifyLog | Out-Null
$verifyCompleted = Get-Date
$verifyDuration = [math]::Round(($verifyCompleted - $verifyStarted).TotalSeconds, 3)
$signtoolExit = $LASTEXITCODE
$signature = Get-AuthenticodeSignature -FilePath $msi.FullName -ErrorAction SilentlyContinue
$actualSubject = $null
$actualThumbprint = $null
$actualVerified = $false
$signatureStatus = $null
if ($signature -and $signature.SignerCertificate) {
    $actualSubject = $signature.SignerCertificate.Subject
    $actualThumbprint = $signature.SignerCertificate.Thumbprint
    $actualVerified = ($signature.Status -eq 'Valid')
    $signatureStatus = $signature.Status
    Write-Summary "Authenticode status: $($signature.Status)"
}
if ($actualSubject) { Write-Summary "Actual subject: $actualSubject" }
if ($actualThumbprint) { Write-Summary "Actual thumbprint: $actualThumbprint" }
$subjectMismatch = $false
$thumbMismatch = $false
if ($expectedSign.subject -and $actualSubject) {
    if ($actualSubject -notlike "*$($expectedSign.subject)*") {
        $subjectMismatch = $true
    }
}
if ($expectedSign.subject -and -not $actualSubject) {
    $subjectMismatch = $true
}
if ($expectedSign.thumbprint -and $actualThumbprint) {
    if (-not [string]::Equals($expectedSign.thumbprint, $actualThumbprint, [System.StringComparison]::OrdinalIgnoreCase)) {
        $thumbMismatch = $true
    }
}
if ($expectedSign.thumbprint -and -not $actualThumbprint) {
    $thumbMismatch = $true
}
$report = [ordered]@{
    channel = $Channel
    expected = $expectedSign
    actual = [ordered]@{
        file_path = $msi.FullName
        subject = $actualSubject
        thumbprint = $actualThumbprint
        verified = $actualVerified
        signature_status = $signatureStatus
    }
    verify = [ordered]@{
        exit_code = $signtoolExit
        log_path = $verifyLog
        started_at = $verifyStarted.ToString("o")
        completed_at = $verifyCompleted.ToString("o")
        duration_seconds = $verifyDuration
        command = $verifyCommand
    }
}
$report | ConvertTo-Json -Depth 6 | Set-Content -Path $reportPath
if ($signtoolExit -ne 0 -or -not $actualVerified -or $subjectMismatch -or $thumbMismatch) {
    $details = "exit=$signtoolExit verified=$actualVerified subjectMismatch=$subjectMismatch thumbMismatch=$thumbMismatch"
    throw "signtool verify failed: $details"
}

$uninstallArgs = "/x `"$($msi.FullName)`" /qn /norestart"
$uninstall = Start-Process -FilePath "msiexec.exe" -ArgumentList $uninstallArgs -PassThru -Wait
if ($uninstall.ExitCode -ne 0) {
    Write-Warning "Uninstall exited with code $($uninstall.ExitCode). Clean up manually if necessary."
}

if ($hasEntry) {
    try {
        Remove-ItemProperty -Path $runKey -Name $appName -ErrorAction Stop
        Write-Summary "Removed $appName registry entry to keep runner clean."
    } catch {
        Write-Warning "Failed to remove run key entry: $($_.Exception.Message)"
    }
}

Write-Summary "Logs: $logDir"
