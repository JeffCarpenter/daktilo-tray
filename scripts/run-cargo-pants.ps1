param(
    [double]$SeverityThreshold,
    [switch]$IncludeDevDependencies,
    [string]$CargoToml = "Cargo.toml",
    [string]$IgnoreFile,
    [string]$ConfigPath = "dist-workspace.toml",
    [string]$Channel
)

. (Join-Path -Path $PSScriptRoot -ChildPath "common-dist.ps1")

function Require-Command {
    param([string]$Name, [string]$InstallHint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' not found. $InstallHint"
    }
}

Require-Command -Name "cargo" -InstallHint "Install Rust via https://rustup.rs/."
Require-Command -Name "cargo-pants" -InstallHint "Install it with 'cargo install cargo-pants --locked'."

$metadata = $null
try {
    $metadata = Get-DistMetadata -Path $ConfigPath
} catch {
    Write-Warning $_.Exception.Message
}

$policy = $null
if ($metadata) {
    $policy = Get-SupplyChainPolicy -Metadata $metadata -Channel $Channel
}

if (-not $PSBoundParameters.ContainsKey("SeverityThreshold")) {
    if ($policy -and $policy.pants_threshold) {
        $SeverityThreshold = [double]$policy.pants_threshold
    } else {
        $SeverityThreshold = 7.0
    }
}

if (-not $PSBoundParameters.ContainsKey("IgnoreFile")) {
    if ($policy -and $policy.ignore_file) {
        $IgnoreFile = $policy.ignore_file
    } else {
        $IgnoreFile = ".pants-ignore"
    }
}

if (-not $PSBoundParameters.ContainsKey("IncludeDevDependencies") -and $policy -and $policy.PSObject.Properties.Name -contains "include_dev_dependencies") {
    $IncludeDevDependencies = [bool]$policy.include_dev_dependencies
}

$cargoArgs = @("pants", "--no-color", "--tomlfile", $CargoToml, "--ignore-file", $IgnoreFile)
if ($IncludeDevDependencies) {
    $cargoArgs += "--dev"
}

if ($Channel) {
    Write-Host "cargo-pants channel: $Channel"
}
Write-Host "Running cargo $($cargoArgs -join ' ') (threshold: $SeverityThreshold)"

$pantsOutput = & cargo @cargoArgs 2>&1 | Tee-Object -Variable lines
$pantsExit = $LASTEXITCODE

$scores = @()
foreach ($line in $lines) {
    if ($line -match "CVSS Score") {
        $match = [regex]::Match($line, "CVSS Score\s+[^\d]*([0-9]+(?:\.[0-9]+)?)")
        if ($match.Success) {
            $scores += [double]$match.Groups[1].Value
        }
    }
}

$maxScore = if ($scores.Count -gt 0) { ($scores | Measure-Object -Maximum).Maximum } else { 0 }

if ($maxScore -ge $SeverityThreshold) {
    throw "cargo-pants detected vulnerabilities with CVSS $maxScore >= threshold $SeverityThreshold."
}

if ($pantsExit -eq 3) {
    Write-Warning "cargo-pants found vulnerabilities (max CVSS $maxScore) but below the failure threshold ($SeverityThreshold). Continuing."
    exit 0
}

if ($pantsExit -ne 0) {
    throw "cargo-pants exited with status $pantsExit."
}
