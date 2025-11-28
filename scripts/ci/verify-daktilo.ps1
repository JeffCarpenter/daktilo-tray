[CmdletBinding()]
param()

 = (Resolve-Path (Join-Path  '..')).Path
 = Join-Path  'vendor/daktilo'
if (-not (Test-Path )) {
    throw "vendor/daktilo submodule missing; run git submodule update --init --recursive"
}
 = Get-Command git -ErrorAction SilentlyContinue
if (-not ) {
    throw "git not found in PATH"
}
 = (git -C  rev-parse --short HEAD).Trim()
Write-Host "daktilo submodule present (commit )"
