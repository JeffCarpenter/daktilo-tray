param(
    [Parameter(Mandatory = $true)][string]$PfxPath,
    [Parameter(Mandatory = $true)][string]$PfxPassword,
    [string]$Repo,
    [string]$EnvFile = ".\.codesign.env",
    [switch]$SkipGitHubSecrets,
    [string]$Environment
)

if (-not (Test-Path $PfxPath)) {
    throw "PFX file not found: $PfxPath"
}

if ($Environment -and -not $Repo) {
    throw "-Environment requires -Repo so gh secret set knows which repository to target."
}

$pfxFullPath = (Resolve-Path $PfxPath).Path
$base64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($pfxFullPath))

if (-not $SkipGitHubSecrets) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI (gh) is required to set secrets. Install it from https://cli.github.com/."
    }

    $secretTargets = @()
    if ($Repo) {
        $secretTargets += @("--repo", $Repo)
    }
    if ($Environment) {
        $secretTargets += @("--env", $Environment)
    }

    Write-Host "Publishing WINDOWS_CODESIGN_PFX secret via gh..."
    gh secret set WINDOWS_CODESIGN_PFX @secretTargets --body $base64

    Write-Host "Publishing WINDOWS_CODESIGN_PASSWORD secret via gh..."
    gh secret set WINDOWS_CODESIGN_PASSWORD @secretTargets --body $PfxPassword
} else {
    Write-Host "SkipGitHubSecrets requested; only writing local env snapshot."
}

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
