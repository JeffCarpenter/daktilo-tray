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

function Resolve-WorkspacePath {
    param(
        [string]$Path,
        [switch]$EnsureDirectory
    )

    if (-not $Path) { return $null }
    $resolved = $Path
    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        $repoRoot = (Resolve-Path (Join-Path -Path $PSScriptRoot -ChildPath "..")).Path
        $resolved = Join-Path -Path $repoRoot -ChildPath $Path
    }
    if ($EnsureDirectory -and -not (Test-Path $resolved)) {
        New-Item -ItemType Directory -Path $resolved -Force | Out-Null
    }
    return $resolved
}

function Invoke-AcmeProvisioning {
    [CmdletBinding()]
    param(
        [psobject]$Metadata,
        [psobject]$AutoSettings,
        [string]$Store,
        [string]$StoreLocation,
        [string]$PfxPassword,
        [string]$Repo,
        [string]$EnvFile,
        [string]$Environment,
        [switch]$SkipGitHubSecrets
    )

    if (-not $AutoSettings) {
        throw "ACME auto-provisioning requested but no settings were provided."
    }
    $profileName = $AutoSettings.acme_profile
    if (-not $profileName) {
        throw "ACME auto-provisioning requires 'acme_profile' metadata."
    }

    $profile = Get-AcmeProfile -Metadata $Metadata -Name $profileName
    if (-not $profile) {
        throw "ACME profile '$profileName' not found in dist metadata."
    }
    $settings = $profile.Settings
    $domains = @($settings.domains)
    if (-not $domains -or $domains.Count -eq 0) {
        throw "ACME profile '$profileName' must declare at least one domain."
    }
    if (-not $settings.email) {
        throw "ACME profile '$profileName' must declare an email address."
    }

    $requestScript = Join-Path -Path $PSScriptRoot -ChildPath "request-acme-pfx.ps1"
    if (-not (Test-Path $requestScript)) {
        throw "Missing helper script: $requestScript"
    }

    $pfxOutputDir = Resolve-WorkspacePath -Path "target\\acme-outputs" -EnsureDirectory
    $pfxPath = Join-Path -Path $pfxOutputDir -ChildPath ("acme-" + $profile.Name + "-" + (Get-Date -Format "yyyyMMddHHmmss") + ".pfx")

    $acmeArgs = @{
        Domains    = $domains
        Email      = [string]$settings.email
        OutputPfx  = $pfxPath
        PfxPassword = $PfxPassword
    }
    if ($settings.state_dir) {
        $acmeArgs.StateDir = Resolve-WorkspacePath -Path ([string]$settings.state_dir) -EnsureDirectory
    }
    if ($settings.caddy_command) {
        $acmeArgs.CaddyCommand = [string]$settings.caddy_command
    }
    if ($settings.acme_server) {
        $acmeArgs.AcmeServer = [string]$settings.acme_server
    }
    if ($settings.use_staging) {
        $acmeArgs.UseStaging = [bool]$settings.use_staging
    }
    if ($settings.timeout_seconds) {
        $acmeArgs.TimeoutSeconds = [int]$settings.timeout_seconds
    }
    if ($settings.dns_provider) {
        $acmeArgs.DnsProvider = [string]$settings.dns_provider
        if ($settings.dns_provider -ieq "cloudflare") {
        $tokenEnv = [string]$settings.cloudflare_token_env
        if (-not $tokenEnv) {
            throw "ACME profile '$($profile.Name)' uses the Cloudflare DNS provider but did not declare 'cloudflare_token_env'."
        }
        $tokenValue = [Environment]::GetEnvironmentVariable($tokenEnv)
        if (-not $tokenValue) {
                throw "Environment variable '$tokenEnv' is not set. Export your Cloudflare token before running the release script."
            }
            $acmeArgs.CloudflareApiToken = $tokenValue
        }
    }

    $result = $null
    try {
        Write-Host "Auto-provisioning ACME certificate via profile '$($profile.Name)' (domains: $($domains -join ', '))."
        & $requestScript @acmeArgs

        if (-not (Test-Path $pfxPath)) {
            throw "ACME provisioning failed; expected PFX at $pfxPath."
        }

        $importedThumbprint = $null
        $importToStore = $true
        if ($AutoSettings.PSObject.Properties.Name -contains "import_to_store") {
            $importToStore = [bool]$AutoSettings.import_to_store
        }
        if ($importToStore) {
            $targetStore = $Store
            if (-not $targetStore) { $targetStore = "My" }
            $targetStoreLocation = $StoreLocation
            if (-not $targetStoreLocation) { $targetStoreLocation = "LocalMachine" }
            $storePath = "Cert:\$targetStoreLocation\$targetStore"
            $securePass = ConvertTo-SecureString -String $PfxPassword -AsPlainText -Force
            $importResult = Import-PfxCertificate -FilePath $pfxPath -CertStoreLocation $storePath -Password $securePass -Exportable -ErrorAction Stop
            $importedCert = $importResult | Select-Object -First 1
            if (-not $importedCert) {
                throw "Import-PfxCertificate did not return a cert for $pfxPath."
            }
            $importedThumbprint = $importedCert.Thumbprint
            Write-Host "Imported ACME certificate into $storePath (thumbprint $importedThumbprint)."
        }

        $prepareScript = Join-Path -Path $PSScriptRoot -ChildPath "prepare-codesign-secrets.ps1"
        if (-not (Test-Path $prepareScript)) {
            throw "Missing helper script: $prepareScript"
        }
        $prepareArgs = @{
            PfxPath     = $pfxPath
            PfxPassword = $PfxPassword
            EnvFile     = $EnvFile
        }
        if ($Repo) { $prepareArgs.Repo = $Repo }
        if ($Environment) { $prepareArgs.Environment = $Environment }
        if ($SkipGitHubSecrets) { $prepareArgs.SkipGitHubSecrets = $true }
        & $prepareScript @prepareArgs

        $result = [pscustomobject]@{
            Thumbprint      = $importedThumbprint
            SecretsPrepared = $true
            ImportedToStore = $importToStore
        }
    }
    finally {
        if (Test-Path $pfxPath) {
            Remove-Item -LiteralPath $pfxPath -Force
        }
    }

    return $result
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

$autoProvisionConfig = $null
$autoProvisionMode = "self_signed"
$autoProvisionImportPreference = $true
$autoProvisionAcmeProfile = $null

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
                $autoProvisionConfig = $autoSettings
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
                if ($autoSettings.mode) {
                    $autoProvisionMode = [string]$autoSettings.mode
                }
                if ($autoSettings.import_to_store -ne $null) {
                    $autoProvisionImportPreference = [bool]$autoSettings.import_to_store
                }
                if ($autoSettings.acme_profile) {
                    $autoProvisionAcmeProfile = [string]$autoSettings.acme_profile
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

$secretsPrepared = $false
if (-not $SkipSecrets) {
    $certificateExists = Test-CertificateExists -SubjectName $SubjectName -Thumbprint $Thumbprint -Store $Store -StoreLocation $StoreLocation
    if (-not $certificateExists -and $AutoProvision) {
        if ($autoProvisionMode -ieq "acme") {
            if (-not $autoProvisionConfig) {
                throw "ACME mode selected but no auto_provision settings found in dist metadata."
            }
            if (-not $autoProvisionAcmeProfile) {
                throw "ACME mode requires 'acme_profile' under the selected channel."
            }
            if (-not $SkipGitHubSecrets -and -not $Repo) {
                throw "ACME provisioning publishes secrets; provide -Repo or declare it in dist metadata."
            }
            $acmeResult = Invoke-AcmeProvisioning `
                -Metadata $metadata `
                -AutoSettings $autoProvisionConfig `
                -Store $Store `
                -StoreLocation $StoreLocation `
                -PfxPassword $PfxPassword `
                -Repo $Repo `
                -EnvFile $EnvFile `
                -Environment $Environment `
                -SkipGitHubSecrets:$SkipGitHubSecrets
            if ($acmeResult.Thumbprint) {
                $Thumbprint = $acmeResult.Thumbprint
            }
            if ($acmeResult.SecretsPrepared) {
                $secretsPrepared = $true
            }
            if ($acmeResult.ImportedToStore) {
                $certificateExists = Test-CertificateExists -SubjectName $SubjectName -Thumbprint $Thumbprint -Store $Store -StoreLocation $StoreLocation
            } else {
                $certificateExists = $secretsPrepared
            }
        } else {
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
    }

    if (-not $certificateExists) {
        throw "No matching certificate found in Cert:\$StoreLocation\$Store. Provide -Thumbprint or run scripts/provision-dev-cert.ps1 to mint one."
    }

    if (-not $secretsPrepared) {
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
