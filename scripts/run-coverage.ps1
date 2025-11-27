param(
    [string]$OutputDir = "target/coverage",
    [switch]$HtmlReport
)

$ErrorActionPreference = "Stop"

function Require-Command {
    param([string]$Name, [string]$InstallHint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' not found. $InstallHint"
    }
}

Require-Command -Name "cargo" -InstallHint "Install Rust via https://rustup.rs/."
Require-Command -Name "cargo-llvm-cov" -InstallHint "Install with 'cargo install cargo-llvm-cov --locked'."

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$lcovPath = Join-Path $OutputDir "lcov.info"
$htmlDir = Join-Path $OutputDir "html"

Write-Host "Cleaning previous coverage artifacts"
cargo llvm-cov clean --workspace

$covArgs = @("llvm-cov", "--workspace", "--lcov", "--output-path", $lcovPath)
if ($HtmlReport) {
    $covArgs += @("--html", "--output-dir", $htmlDir)
}

Write-Host "Running cargo $($covArgs -join ' ')"
cargo @covArgs

if (-not (Test-Path $lcovPath)) {
    throw "Expected LCOV report at $lcovPath"
}

Write-Host "Coverage artifacts written to $OutputDir"
