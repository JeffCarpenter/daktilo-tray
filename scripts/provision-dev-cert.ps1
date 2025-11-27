param(
    [Parameter(Mandatory = $true)][string]$SubjectName,
    [Parameter(Mandatory = $true)][string]$PfxPassword,
    [string]$Repo,
    [string]$EnvFile = ".\.codesign.env",
    [string]$Store = "My",
    [ValidateSet("CurrentUser", "LocalMachine")][string]$StoreLocation = "CurrentUser",
    [int]$ValidDays = 365,
    [ValidateSet("SHA256", "SHA384", "SHA512")][string]$HashAlgorithm = "SHA256",
    [int]$KeyLength = 4096,
    [switch]$SkipGitHubSecrets
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($SubjectName)) {
    throw "SubjectName cannot be empty. Example: -SubjectName 'CN=Daktilo Tray Dev'"
}

$storePath = "Cert:\$StoreLocation\$Store"
if (-not (Test-Path $storePath)) {
    throw "Certificate store not found: $storePath"
}

$notAfter = (Get-Date).AddDays($ValidDays)
Write-Host "Creating self-signed code signing certificate for $SubjectName valid until $($notAfter.ToUniversalTime().ToString("u"))."

$cert = New-SelfSignedCertificate `
    -Subject $SubjectName `
    -Type CodeSigningCert `
    -CertStoreLocation $storePath `
    -NotAfter $notAfter `
    -KeyExportPolicy Exportable `
    -KeyLength $KeyLength `
    -HashAlgorithm $HashAlgorithm `
    -FriendlyName $SubjectName

if (-not $cert) {
    throw "Failed to create code signing certificate."
}

$tempPfx = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("dev-codesign-" + [guid]::NewGuid().ToString() + ".pfx")
$securePass = ConvertTo-SecureString -String $PfxPassword -AsPlainText -Force
Export-PfxCertificate -Cert $cert -FilePath $tempPfx -Password $securePass -ChainOption BuildChain -Force | Out-Null

try {
    $prepareScript = Join-Path -Path $PSScriptRoot -ChildPath "prepare-codesign-secrets.ps1"
    if (-not (Test-Path $prepareScript)) {
        throw "Missing helper script: $prepareScript"
    }
    $prepareArgs = @{
        PfxPath            = $tempPfx
        PfxPassword        = $PfxPassword
        EnvFile            = $EnvFile
        SkipGitHubSecrets  = $SkipGitHubSecrets
    }
    if ($Repo) {
        $prepareArgs.Repo = $Repo
    }
    & $prepareScript @prepareArgs
}
finally {
    if (Test-Path $tempPfx) {
        Remove-Item -LiteralPath $tempPfx -Force
    }
}

Write-Host "Created certificate with thumbprint $($cert.Thumbprint). Import trust manually if you want Windows to honor signatures from this dev cert."
