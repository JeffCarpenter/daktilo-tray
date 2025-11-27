param(
    [string]$SubjectName,
    [string]$Thumbprint,
    [string]$Store,
    [ValidateSet("CurrentUser", "LocalMachine")][string]$StoreLocation,
    [Parameter(Mandatory = $true)][string]$PfxPassword,
    [Parameter(Mandatory = $true)][string]$Repo,
    [string]$EnvFile = ".\.codesign.env",
    [string[]]$DistArgs = @("--installer", "msi"),
    [switch]$SkipSecrets,
    [string]$Tag,
    [string]$Channel,
    [string]$ConfigPath = "dist-workspace.toml"
)

. (Join-Path -Path $PSScriptRoot -ChildPath "common-dist.ps1")

$ErrorActionPreference = "Stop"

function Require-Command {
    param([string]$Name, [string]$InstallHint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' not found. $InstallHint"
    }
}

Require-Command -Name "gh" -InstallHint "Install GitHub CLI from https://cli.github.com/."
Require-Command -Name "dist" -InstallHint "Install cargo-dist via 'cargo install cargo-dist' or see https://github.com/axodotdev/cargo-dist." 
try {
    $resolvedSignTool = Get-SignToolPath
    Write-Host "Using signtool at $resolvedSignTool"
} catch {
    throw $_
}
Require-Command -Name "git" -InstallHint "Install Git for Windows."

$metadata = $null
try {
    $metadata = Get-DistMetadata -Path $ConfigPath
} catch {
    Write-Warning $_.Exception.Message
}
$channelProfile = $null
if ($metadata) {
    $channelProfile = Get-CodesignProfile -Metadata $metadata -Channel $Channel
    if ($channelProfile) {
        $resolvedChannel = $channelProfile.Name
        $settings = $channelProfile.Settings
        if (-not $PSBoundParameters.ContainsKey("Store") -and $settings.store) {
            $Store = $settings.store
        }
        if (-not $PSBoundParameters.ContainsKey("StoreLocation") -and $settings.store_location) {
            $StoreLocation = $settings.store_location
        }
        if (-not $PSBoundParameters.ContainsKey("SubjectName") -and $settings.subject) {
            $SubjectName = $settings.subject
        }
        if (-not $PSBoundParameters.ContainsKey("Thumbprint") -and $settings.thumbprint) {
            $Thumbprint = $settings.thumbprint
        }
        if (-not $PSBoundParameters.ContainsKey("EnvFile") -and $settings.env_file) {
            $EnvFile = $settings.env_file
        }
        if ($resolvedChannel) {
            Write-Host "Codesign channel resolved to '$resolvedChannel' via dist metadata."
        }
    } else {
        if ($Channel) {
            Write-Warning "No codesign settings found for channel '$Channel'. Falling back to CLI arguments."
        }
    }
}

if (-not $Store) { $Store = "My" }
if (-not $StoreLocation) { $StoreLocation = "LocalMachine" }

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
