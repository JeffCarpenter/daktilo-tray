param(
    [string]$OutputDir = "target/coverage",
    [switch]$HtmlReport,
    [string]$SummaryPath
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
$jsonSummaryPath = Join-Path $OutputDir "summary.json"
if (-not $SummaryPath) {
    $SummaryPath = Join-Path $OutputDir "summary.md"
}

Write-Host "Cleaning previous coverage artifacts"
cargo llvm-cov clean --workspace

$covArgs = @("llvm-cov", "--workspace", "--lcov", "--output-path", $lcovPath)

Write-Host "Running cargo $($covArgs -join ' ')"
cargo @covArgs

if (-not (Test-Path $lcovPath)) {
    throw "Expected LCOV report at $lcovPath"
}

$generateHtmlArgs = $null
if ($HtmlReport) {
    $generateHtmlArgs = @("llvm-cov", "report", "--html", "--output-dir", $htmlDir)
    Write-Host "Generating HTML report with cargo $($generateHtmlArgs -join ' ')"
    cargo @generateHtmlArgs
}

Write-Host "Exporting JSON coverage summary"
$summaryArgs = @("llvm-cov", "report", "--json", "--output-path", $jsonSummaryPath, "--summary-only")
cargo @summaryArgs

if (-not (Test-Path $jsonSummaryPath)) {
    throw "Expected JSON summary at $jsonSummaryPath"
}

$json = Get-Content $jsonSummaryPath -Raw | ConvertFrom-Json
$data = @($json.data)

function Accumulate-Metric {
    param(
        [string]$Metric
    )
    $counts = @{ covered = 0; total = 0; percent = 0.0 }
    foreach ($entry in $data) {
        if ($entry.totals -and $entry.totals.$Metric) {
            $counts.covered += [double]($entry.totals.$Metric.covered)
            if ($entry.totals.$Metric.PSObject.Properties.Name -contains "notcovered") {
                $counts.total += [double]($entry.totals.$Metric.covered + $entry.totals.$Metric.notcovered)
            } elseif ($entry.totals.$Metric.PSObject.Properties.Name -contains "count") {
                $counts.total += [double]($entry.totals.$Metric.count)
            }
        }
    }
    if ($counts.total -gt 0) {
        $counts.percent = [math]::Round(($counts.covered / $counts.total) * 100, 2)
    }
    return $counts
}

$lineStats = Accumulate-Metric -Metric "lines"
$regionStats = Accumulate-Metric -Metric "regions"
$functionStats = Accumulate-Metric -Metric "functions"

$summaryLines = @(
    "# Coverage Summary",
    "",
    "| Metric | Covered | Total | Percent |",
    "|--------|---------|-------|---------|",
    "| Lines | {0} | {1} | {2}% |" -f [int]$lineStats.covered, [int]$lineStats.total, $lineStats.percent,
    "| Regions | {0} | {1} | {2}% |" -f [int]$regionStats.covered, [int]$regionStats.total, $regionStats.percent,
    "| Functions | {0} | {1} | {2}% |" -f [int]$functionStats.covered, [int]$functionStats.total, $functionStats.percent,
    "",
    "_Generated $(Get-Date -Format s)_"
)
$summaryLines | Set-Content -Encoding UTF8 -Path $SummaryPath

Write-Host "Coverage artifacts written to $OutputDir"
Write-Host "Summary markdown written to $SummaryPath"
