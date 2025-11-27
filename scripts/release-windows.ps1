param(
    [string]$SubjectName,
    [string]$Thumbprint,
    [string]$Store = "My",
    [ValidateSet("CurrentUser", "LocalMachine")][string]$StoreLocation = "LocalMachine",
    [Parameter(Mandatory = $true)][string]$PfxPassword,
    [Parameter(Mandatory = $true)][string]$Repo,
    [string]$EnvFile = ".\.codesign.env",
    [string[]]$DistArgs = @("--installer", "msi"),
    [switch]$SkipSecrets,
    [string]$Tag
)

$ErrorActionPreference = "Stop"

function Require-Command {
    param([string]$Name, [string]$InstallHint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' not found. $InstallHint"
    }
}

Require-Command -Name "gh" -InstallHint "Install GitHub CLI from https://cli.github.com/."
Require-Command -Name "dist" -InstallHint "Install cargo-dist via 'cargo install cargo-dist' or see https://github.com/axodotdev/cargo-dist." 
Require-Command -Name "signtool.exe" -InstallHint "Install the Windows SDK so signtool.exe is available."
Require-Command -Name "git" -InstallHint "Install Git for Windows."

$bootstrapScript = Join-Path -Path $PSScriptRoot -ChildPath "bootstrap-codesign.ps1"
if (-not (Test-Path $bootstrapScript)) {
    throw "Missing helper script: $bootstrapScript"
}

if (-not $SkipSecrets) {
    if (-not ($SubjectName -or $Thumbprint)) {
        throw "Provide -SubjectName or -Thumbprint when exporting secrets."
    }
    $bootstrapArgs = @{}
    if ($SubjectName) { $bootstrapArgs.SubjectName = $SubjectName }
    if ($Thumbprint) { $bootstrapArgs.Thumbprint = $Thumbprint }
    $bootstrapArgs.Store = $Store
    $bootstrapArgs.StoreLocation = $StoreLocation
    $bootstrapArgs.PfxPassword = $PfxPassword
    $bootstrapArgs.Repo = $Repo
    $bootstrapArgs.EnvFile = $EnvFile
    & $bootstrapScript @bootstrapArgs
}

if (-not (Test-Path $EnvFile)) {
    throw "Codesign env file not found at $EnvFile. Run without -SkipSecrets first."
}

$envLines = Get-Content $EnvFile | Where-Object { $_ -match "=" }
$envMap = @{}
foreach ($line in $envLines) {
    $parts = $line.Split("=", 2)
    if ($parts.Count -eq 2) {
        $envMap[$parts[0]] = $parts[1]
    }
}
if (-not $envMap.ContainsKey("WINDOWS_CODESIGN_PFX")) {
    throw "WINDOWS_CODESIGN_PFX not found in $EnvFile"
}
if (-not $envMap.ContainsKey("WINDOWS_CODESIGN_PASSWORD")) {
    throw "WINDOWS_CODESIGN_PASSWORD not found in $EnvFile"
}
$base64 = $envMap["WINDOWS_CODESIGN_PFX"]
$password = $envMap["WINDOWS_CODESIGN_PASSWORD"]

$env:WINDOWS_CODESIGN_PFX = $base64
$env:WINDOWS_CODESIGN_PASSWORD = $password

Write-Host "Running cargo-dist ($($DistArgs -join ' '))"
& dist build --allow-dirty @DistArgs

$signScript = Join-Path -Path $PSScriptRoot -ChildPath "sign-windows.ps1"
if (-not (Test-Path $signScript)) {
    throw "Missing signing script: $signScript"
}
Write-Host "Signing build artifacts"
& $signScript -ArtifactsDir "target/distrib" -BinaryDir "target/dist" -PfxBase64 $base64 -PfxPassword $password

if ($Tag) {
    Write-Host "Tagging release $Tag"
    git tag $Tag
    git push origin $Tag
}
