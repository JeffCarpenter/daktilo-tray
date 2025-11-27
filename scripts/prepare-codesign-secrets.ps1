param(
    [Parameter(Mandatory = $true)][string]$PfxPath,
    [Parameter(Mandatory = $true)][string]$PfxPassword,
    [string]$Repo,
    [string]$EnvFile = ".\.codesign.env"
)

if (-not (Test-Path $PfxPath)) {
    throw "PFX file not found: $PfxPath"
}

$pfxFullPath = (Resolve-Path $PfxPath).Path
$base64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($pfxFullPath))

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) is required to set secrets. Install it from https://cli.github.com/."
}

$secretTargets = @()
if ($Repo) {
    $secretTargets += @("--repo", $Repo)
}

Write-Host "Publishing WINDOWS_CODESIGN_PFX secret via gh..."
gh secret set WINDOWS_CODESIGN_PFX @secretTargets --body $base64

Write-Host "Publishing WINDOWS_CODESIGN_PASSWORD secret via gh..."
gh secret set WINDOWS_CODESIGN_PASSWORD @secretTargets --body $PfxPassword

$envContent = @(
    "WINDOWS_CODESIGN_PFX=$base64",
    "WINDOWS_CODESIGN_PASSWORD=$PfxPassword"
)
$envDir = Split-Path -Path $EnvFile -Parent
if (-not (Test-Path $envDir)) {
    New-Item -ItemType Directory -Force -Path $envDir | Out-Null
}
$envContent | Out-File -Encoding UTF8 -FilePath $EnvFile
Write-Host "Wrote local env snapshot to $EnvFile (keep it private!)."
