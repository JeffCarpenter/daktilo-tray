param(
    [string]$OutputDir = "target/coverage",
    [switch]$HtmlReport,
    [switch]$GenerateJUnit,
    [string]$JUnitDir = "target/test-results",
    [switch]$AppendToStepSummary,
    [string]$DistMetadataPath = "dist-workspace.toml"
)

$ErrorActionPreference = "Stop"

function Require-Command {
    param([string]$Name, [string]$InstallHint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' not found. $InstallHint"
    }
}

function ConvertFrom-TomlFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        return $null
    }
    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        Write-Warning "python not found; skipping TOML metadata parsing"
        return $null
    }
    $pythonScript = 'import json, pathlib, sys, tomllib; path = pathlib.Path(sys.argv[1]); data = tomllib.loads(path.read_text(encoding="utf-8")); json.dump(data, sys.stdout)'
    $json = & python -c $pythonScript $Path
    if (-not $json) {
        return $null
    }
    return $json | ConvertFrom-Json
}

function Accumulate-Metric {
    param($Data, [string]$Metric)
    $stats = [ordered]@{ covered = 0.0; total = 0.0; percent = 0.0 }
    foreach ($entry in $Data) {
        if (-not $entry.totals) { continue }
        $metricTotals = $entry.totals.$Metric
        if (-not $metricTotals) { continue }
        if ($metricTotals.PSObject.Properties.Name -contains "covered") {
            $stats.covered += [double]$metricTotals.covered
        }
        if ($metricTotals.PSObject.Properties.Name -contains "notcovered") {
            $stats.total += [double]($metricTotals.covered + $metricTotals.notcovered)
        } elseif ($metricTotals.PSObject.Properties.Name -contains "count") {
            $stats.total += [double]$metricTotals.count
        }
    }
    if ($stats.total -gt 0) {
        $stats.percent = [math]::Round(($stats.covered / $stats.total) * 100, 2)
    }
    return $stats
}

function Format-Delta {
    param([double]$Value)
    $rounded = [math]::Round($Value, 2)
    $sign = if ($rounded -ge 0) { "+" } else { "" }
    return "{0}{1}%" -f $sign, $rounded
}

function Invoke-TestRun {
    param(
        [string]$OutputDir,
        [string]$JUnitPath,
        [string]$ExitCodePath
    )
    Require-Command -Name "cargo2junit" -InstallHint "Install with 'cargo install cargo2junit --locked'."
    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }
    $jsonPath = Join-Path $OutputDir "cargo-test.json"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "cargo"
    foreach ($arg in @("test","--workspace","--all-targets","--message-format","json")) {
        [void]$psi.ArgumentList.Add($arg)
    }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $null = $process.Start()
    $stdOut = $process.StandardOutput.ReadToEnd()
    $stdErr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $exitCode = $process.ExitCode
    $stdOut | Set-Content -Encoding UTF8 -Path $jsonPath
    Set-Content -Encoding UTF8 -Path $ExitCodePath -Value $exitCode
    if ($stdErr) {
        Write-Warning $stdErr
    }
    if ($exitCode -ne 0) {
        Write-Warning "cargo test exited with code $exitCode (JUnit report still generated)"
    } else {
        Write-Host "cargo test exited successfully"
    }
    $testEventCount = 0
    if (Test-Path $jsonPath) {
        $testEventCount = (Select-String -Path $jsonPath -Pattern '"type":"test"' -SimpleMatch | Measure-Object).Count
    }
    if ($testEventCount -eq 0) {
        Write-Warning "No test events found; writing placeholder JUnit report"
        $timestamp = Get-Date -Format s
        $placeholder = @(
            "<?xml version=`"1.0`" encoding=`"UTF-8`"?>",
            "<testsuites tests=`"0`" failures=`"0`" errors=`"0`" skipped=`"0`" time=`"0`">",
            "  <testsuite name=`"cargo test`" tests=`"0`" failures=`"0`" errors=`"0`" skipped=`"0`" time=`"0`" timestamp=`"$timestamp`" />",
            "</testsuites>"
        )
        $placeholder | Set-Content -Encoding UTF8 -Path $JUnitPath
    } else {
        & cargo2junit 0< $jsonPath 1> $JUnitPath
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "cargo2junit exited with code $LASTEXITCODE"
        }
    }
    return @{ JsonPath = $jsonPath; JunitPath = $JUnitPath; ExitCodePath = $ExitCodePath }
}

function Write-CoverageSummary {
    param(
        [string]$SummaryJsonPath,
        [string]$MarkdownPath,
        [string]$DistMetadataPath,
        [string]$JUnitPath,
        [string]$ExitCodePath,
        [switch]$AppendToStepSummary
    )
    if (-not (Test-Path $SummaryJsonPath)) {
        throw "Coverage summary JSON missing at $SummaryJsonPath"
    }
    $json = Get-Content $SummaryJsonPath -Raw | ConvertFrom-Json
    $data = @($json.data)
    $lineStats = Accumulate-Metric -Data $data -Metric "lines"
    $regionStats = Accumulate-Metric -Data $data -Metric "regions"
    $functionStats = Accumulate-Metric -Data $data -Metric "functions"

    $metadata = ConvertFrom-TomlFile -Path $DistMetadataPath
    $baseline = $metadata?.workspace?.metadata?.dist?.coverage?.baseline

    function Get-BaselineValue {
        param($BaselineTable, [string]$Metric)
        if ($BaselineTable -and $BaselineTable.PSObject.Properties.Name -contains $Metric) {
            return [double]$BaselineTable.$Metric
        }
        return 0.0
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# Test & Coverage Summary")
    $lines.Add("")
    $lines.Add("## Coverage")
    $lines.Add("")
    $lines.Add("| Metric | Covered | Total | Percent | Delta vs Baseline |")
    $lines.Add("|--------|---------|-------|---------|-------------------|")

    $coverageEntries = @(
        [ordered]@{Name="Lines"; Stats=$lineStats; Key="lines"},
        [ordered]@{Name="Regions"; Stats=$regionStats; Key="regions"},
        [ordered]@{Name="Functions"; Stats=$functionStats; Key="functions"}
    )

    foreach ($entry in $coverageEntries) {
        $baselineValue = Get-BaselineValue -BaselineTable $baseline -Metric $entry.Key
        $delta = $entry.Stats.percent - $baselineValue
        $row = "| {0} | {1} | {2} | {3}% | {4} |" -f `
            $entry.Name,
            [int][math]::Round($entry.Stats.covered, 0),
            [int][math]::Round($entry.Stats.total, 0),
            $entry.Stats.percent,
            (Format-Delta -Value $delta)
        $lines.Add($row)
    }

    $lines.Add("")
    if ($baseline) {
        $lines.Add("Baseline source: dist-workspace.toml")
        $lines.Add("")
    }

    $testStats = $null
    if ($JUnitPath -and (Test-Path $JUnitPath)) {
        [xml]$junit = Get-Content $JUnitPath -Raw
        $suites = @()
        if ($junit.testsuites) { $suites = @($junit.testsuites.testsuite) }
        elseif ($junit.testsuite) { $suites = @($junit.testsuite) }
        $suites = $suites | Where-Object { $_ }
        if ($suites.Count -gt 0) {
            $tests = 0
            $failures = 0
            $errors = 0
            $skipped = 0
            $duration = 0.0
            foreach ($suite in $suites) {
                $tests += [int]($suite.tests | ForEach-Object { $_ })
                $failures += [int]($suite.failures | ForEach-Object { $_ })
                $errors += [int]($suite.errors | ForEach-Object { $_ })
                $skipped += [int]($suite.skipped | ForEach-Object { $_ })
                $duration += [double]($suite.time | ForEach-Object { $_ })
            }
            $testStats = [ordered]@{
                tests = $tests
                failures = $failures + $errors
                skipped = $skipped
                duration = [math]::Round($duration, 2)
            }
        }
    }

    $lines.Add("## Tests")
    $lines.Add("")
    if ($testStats) {
        $exitCode = $null
        if ($ExitCodePath -and (Test-Path $ExitCodePath)) {
            $raw = (Get-Content $ExitCodePath -Raw).Trim()
            if ($raw) { $exitCode = [int]$raw }
        }
        if ($exitCode -and $exitCode -ne 0) {
            $lines.Add("**Status:** FAIL (tests failed)")
        } elseif ($testStats.tests -eq 0) {
            $lines.Add("**Status:** INFO (no tests executed)")
        } else {
            $lines.Add("**Status:** PASS (tests passed)")
        }
        $lines.Add("")
        $lines.Add("| Metric | Count |")
        $lines.Add("|--------|-------|")
        $passed = $testStats.tests - $testStats.failures - $testStats.skipped
        $lines.Add("| Total | {0} |" -f $testStats.tests)
        $lines.Add("| Passed | {0} |" -f $passed)
        $lines.Add("| Failed | {0} |" -f $testStats.failures)
        $lines.Add("| Skipped | {0} |" -f $testStats.skipped)
        $lines.Add("| Duration (s) | {0} |" -f $testStats.duration)
    } else {
        $lines.Add("No JUnit report was found at $JUnitPath.")
    }

    $lines.Add("")
    $lines.Add("_Generated $(Get-Date -Format s)_")

    $lines | Set-Content -Encoding UTF8 -Path $MarkdownPath
    Write-Host "Summary markdown written to $MarkdownPath"

    if ($AppendToStepSummary -and $env:GITHUB_STEP_SUMMARY) {
        $lines | Out-String | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Encoding utf8 -Append
        Write-Host "Appended summary to GITHUB_STEP_SUMMARY"
    } elseif ($AppendToStepSummary) {
        Write-Warning "GITHUB_STEP_SUMMARY not set; skipping append"
    }
}

Require-Command -Name "cargo" -InstallHint "Install Rust via https://rustup.rs/."
Require-Command -Name "cargo-llvm-cov" -InstallHint "Install with 'cargo install cargo-llvm-cov --locked'."

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}
if ($GenerateJUnit -and -not (Test-Path $JUnitDir)) {
    New-Item -ItemType Directory -Path $JUnitDir -Force | Out-Null
}

$lcovPath = Join-Path $OutputDir "lcov.info"
$htmlDir = Join-Path $OutputDir "html"
$jsonSummaryPath = Join-Path $OutputDir "summary.json"
$summaryMarkdownPath = Join-Path $OutputDir "summary.md"
$testExitPath = if ($GenerateJUnit) { Join-Path $JUnitDir "exit-code.txt" } else { $null }
$JUnitPath = if ($GenerateJUnit) { Join-Path $JUnitDir "junit.xml" } else { $null }

Write-Host "Cleaning previous coverage artifacts"
cargo llvm-cov clean --workspace

$covArgs = @("llvm-cov", "--workspace", "--lcov", "--output-path", $lcovPath)
Write-Host "Running cargo $($covArgs -join ' ')"
cargo @covArgs

if (-not (Test-Path $lcovPath)) {
    throw "Expected LCOV report at $lcovPath"
}

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

$testResult = @{ JunitPath = $null; ExitCodePath = $null }
if ($GenerateJUnit) {
    $testResult = Invoke-TestRun -OutputDir $JUnitDir -JUnitPath $JUnitPath -ExitCodePath $testExitPath
}

Write-CoverageSummary `
    -SummaryJsonPath $jsonSummaryPath `
    -MarkdownPath $summaryMarkdownPath `
    -DistMetadataPath $DistMetadataPath `
    -JUnitPath $testResult.JunitPath `
    -ExitCodePath $testResult.ExitCodePath `
    -AppendToStepSummary:$AppendToStepSummary

Write-Host "Coverage artifacts written to $OutputDir"
if ($GenerateJUnit) {
    Write-Host "Test artifacts written to $JUnitDir"
}
