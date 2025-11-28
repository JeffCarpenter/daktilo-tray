param(
    [string]$SubjectName,
    [string]$Thumbprint,
    [string]$Store,
    [ValidateSet("CurrentUser", "LocalMachine")][string]$StoreLocation,
    [Parameter(Mandatory = $true)][string]$PfxPassword,
    [string]$Repo,
    [string]$EnvFile = ".\.codesign.env",
    [string]$Environment,
    [string[]]$DistArgs = @("--installer", "msi"),
    [switch]$SkipSecrets,
    [switch]$SkipGitHubSecrets,
    [string]$Tag,
    [string]$Channel,
    [string]$ConfigPath = "dist-workspace.toml",
    [switch]$AllowDirty,
    [switch]$AutoProvision,
    [int]$AutoProvisionValidDays = 365,
    [ValidateSet("SHA256", "SHA384", "SHA512")][string]$AutoProvisionHashAlgorithm = "SHA256",
    [int]$AutoProvisionKeyLength = 4096
)

. (Join-Path -Path $PSScriptRoot -ChildPath "common-dist.ps1")

$ErrorActionPreference = "Stop"

function Require-Command {
    param([string]$Name, [string]$InstallHint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' not found. $InstallHint"
    }
}

function Test-CertificateExists {
    param(
        [string]$SubjectName,
        [string]$Thumbprint,
        [string]$Store,
        [string]$StoreLocation
    )

    $storePath = "Cert:\$StoreLocation\$Store"
    if (-not (Test-Path $storePath)) {
        return $false
    }

    $certs = @(Get-ChildItem $storePath)
    if ($Thumbprint) {
        $normalized = $Thumbprint.Replace(" ", "").ToUpperInvariant()
        $certs = $certs | Where-Object { $_.Thumbprint.Replace(" ", "").ToUpperInvariant() -eq $normalized }
    }
    if ($SubjectName) {
        $certs = $certs | Where-Object { $_.Subject -like "*$SubjectName*" }
    }
    return $certs.Count -gt 0
}

function New-SelfSignedCodeSigningCert {
    param(
        [Parameter(Mandatory = $true)][string]$SubjectName,
        [Parameter(Mandatory = $true)][string]$Store,
        [Parameter(Mandatory = $true)][string]$StoreLocation,
        [int]$ValidDays = 365,
        [int]$KeyLength = 4096,
        [ValidateSet("SHA256", "SHA384", "SHA512")][string]$HashAlgorithm = "SHA256"
    )

    $storePath = "Cert:\$StoreLocation\$Store"
    if (-not (Test-Path $storePath)) {
        throw "Cannot auto-provision certificate because store '$storePath' does not exist."
    }

    $notAfter = (Get-Date).AddDays($ValidDays)
    Write-Host "Auto-provisioning self-signed code signing certificate '$SubjectName' in $storePath (valid until $($notAfter.ToUniversalTime().ToString('u')))."
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
        throw "Failed to auto-provision a self-signed certificate for $SubjectName."
    }

    return $cert
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
        if (-not $PSBoundParameters.ContainsKey("Repo") -and $settings.repo) {
            $Repo = $settings.repo
        }
        if (-not $PSBoundParameters.ContainsKey("Environment") -and $settings.environment) {
            $Environment = $settings.environment
        }
        if ($settings.auto_provision) {
            $autoSettings = $settings.auto_provision
            if ($autoSettings -is [bool]) {
                if (-not $PSBoundParameters.ContainsKey("AutoProvision")) {
                    $AutoProvision = [bool]$autoSettings
                }
            } elseif ($autoSettings.PSObject.Properties.Count -gt 0) {
                if (-not $PSBoundParameters.ContainsKey("AutoProvision") -and $autoSettings.enabled -ne $null) {
                    $AutoProvision = [bool]$autoSettings.enabled
                }
                if (-not $PSBoundParameters.ContainsKey("AutoProvisionValidDays") -and $autoSettings.valid_days) {
                    $AutoProvisionValidDays = [int]$autoSettings.valid_days
                }
                if (-not $PSBoundParameters.ContainsKey("AutoProvisionHashAlgorithm") -and $autoSettings.hash_algorithm) {
                    $AutoProvisionHashAlgorithm = [string]$autoSettings.hash_algorithm
                }
                if (-not $PSBoundParameters.ContainsKey("AutoProvisionKeyLength") -and $autoSettings.key_length) {
                    $AutoProvisionKeyLength = [int]$autoSettings.key_length
                }
            }
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
    $certificateExists = Test-CertificateExists -SubjectName $SubjectName -Thumbprint $Thumbprint -Store $Store -StoreLocation $StoreLocation
    if (-not $certificateExists -and $AutoProvision) {
        if (-not $SubjectName) {
            throw "Auto-provisioning needs -SubjectName to synthesize a cert."
        }
        New-SelfSignedCodeSigningCert `
            -SubjectName $SubjectName `
            -Store $Store `
            -StoreLocation $StoreLocation `
            -ValidDays $AutoProvisionValidDays `
            -KeyLength $AutoProvisionKeyLength `
            -HashAlgorithm $AutoProvisionHashAlgorithm | Out-Null
        $certificateExists = Test-CertificateExists -SubjectName $SubjectName -Thumbprint $Thumbprint -Store $Store -StoreLocation $StoreLocation
    }

    if (-not $certificateExists) {
        throw "No matching certificate found in Cert:\$StoreLocation\$Store. Provide -Thumbprint or run scripts/provision-dev-cert.ps1 to mint one."
    }

    if (-not ($SubjectName -or $Thumbprint)) {
        throw "Provide -SubjectName or -Thumbprint when exporting secrets."
    }
    if (-not $Repo) {
        throw "Provide -Repo or declare 'repo' under the selected codesign channel in dist-workspace.toml."
    }
    $bootstrapArgs = @{}
    if ($SubjectName) { $bootstrapArgs.SubjectName = $SubjectName }
    if ($Thumbprint) { $bootstrapArgs.Thumbprint = $Thumbprint }
    $bootstrapArgs.Store = $Store
    $bootstrapArgs.StoreLocation = $StoreLocation
    $bootstrapArgs.PfxPassword = $PfxPassword
    $bootstrapArgs.Repo = $Repo
    $bootstrapArgs.EnvFile = $EnvFile
    if ($Environment) { $bootstrapArgs.Environment = $Environment }
    if ($SkipGitHubSecrets) { $bootstrapArgs.SkipGitHubSecrets = $true }
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

if (-not $AllowDirty) {
    $gitStatus = git status --porcelain
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to read git status (exit $LASTEXITCODE)."
    }
    if ($gitStatus) {
        throw "Working tree has uncommitted changes. Commit/stash them or pass -AllowDirty to override."
    }
}

$distBuildArgs = @("build")
if ($AllowDirty) {
    $distBuildArgs += "--allow-dirty"
}
$distBuildArgs += $DistArgs

Write-Host "Running cargo-dist $($distBuildArgs -join ' ')"
& dist @distBuildArgs

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
