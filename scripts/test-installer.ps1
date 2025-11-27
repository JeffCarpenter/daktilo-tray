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
& $signTool verify /pa /v "$($msi.FullName)" 2>&1 | Tee-Object -FilePath $verifyLog | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "signtool verify failed with exit code $LASTEXITCODE"
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
