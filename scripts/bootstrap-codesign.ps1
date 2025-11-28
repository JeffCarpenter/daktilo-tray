param(
    [string]$SubjectName,
    [string]$Thumbprint,
    [string]$Store = "My",
    [ValidateSet("CurrentUser", "LocalMachine")][string]$StoreLocation = "CurrentUser",
    [Parameter(Mandatory = $true)][string]$PfxPassword,
    [string]$Repo,
    [string]$EnvFile = ".\.codesign.env",
    [string]$Environment,
    [switch]$SkipGitHubSecrets
)

if (-not ($SubjectName -or $Thumbprint)) {
    throw "Provide -SubjectName or -Thumbprint to identify the certificate."
}

$storePath = "Cert:\$StoreLocation\$Store"
if (-not (Test-Path $storePath)) {
    throw "Store not found: $storePath"
}

$certs = @(Get-ChildItem $storePath)
if ($Thumbprint) {
    $normalized = $Thumbprint.Replace(" ", "").ToUpperInvariant()
    $certs = $certs | Where-Object { $_.Thumbprint.Replace(" ", "").ToUpperInvariant() -eq $normalized }
}
if ($SubjectName) {
    $certs = $certs | Where-Object { $_.Subject -like "*$SubjectName*" }
}
$certs = @($certs)

if (-not $certs) {
    throw "No matching certificate found in $storePath"
}
if ($certs.Count -gt 1) {
    throw "Multiple certificates matched. Narrow it down with -Thumbprint."
}

$tempPfx = Join-Path -Path $env:TEMP -ChildPath ("codesign-export-" + [guid]::NewGuid().ToString() + ".pfx")
$securePass = ConvertTo-SecureString -String $PfxPassword -AsPlainText -Force
Export-PfxCertificate -Cert $certs[0] -FilePath $tempPfx -Password $securePass -ChainOption BuildChain -Force | Out-Null

try {
    $prepareScript = Join-Path -Path $PSScriptRoot -ChildPath "prepare-codesign-secrets.ps1"
    if (-not (Test-Path $prepareScript)) {
        throw "Missing helper script: $prepareScript"
    }
    $prepareArgs = @{
        PfxPath    = $tempPfx
        PfxPassword = $PfxPassword
        Repo       = $Repo
        EnvFile    = $EnvFile
    }
    if ($Environment) {
        $prepareArgs.Environment = $Environment
    }
    if ($SkipGitHubSecrets) {
        $prepareArgs.SkipGitHubSecrets = $true
    }
    & $prepareScript @prepareArgs
}
finally {
    if (Test-Path $tempPfx) {
        Remove-Item -LiteralPath $tempPfx -Force
    }
}
