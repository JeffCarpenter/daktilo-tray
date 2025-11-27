# Shared helpers for reading dist-workspace metadata so our scripts stay in sync

function Get-DistMetadata {
    [CmdletBinding()]
    param(
        [string]$Path = (Join-Path -Path (Get-Location) -ChildPath "dist-workspace.toml")
    )

    if (-not (Test-Path $Path)) {
        throw "dist-workspace metadata not found at $Path"
    }

    if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
        throw "Python 3.11+ is required to parse $Path. Install it and retry."
    }

    $parser = @'
import json
import sys

try:
    import tomllib as toml
except ModuleNotFoundError:
    import tomli as toml

path = sys.argv[1]
with open(path, "rb") as fh:
    data = toml.load(fh)

print(json.dumps(data))
'@

    $json = & python -c $parser $Path
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
        throw "Failed to parse dist metadata from $Path"
    }

    return $json | ConvertFrom-Json
}

function Get-SignToolPath {
    [CmdletBinding()]
    param(
        [string]$Override
    )

    if ($Override) {
        if (-not (Test-Path $Override)) {
            throw "Provided SignTool path '$Override' does not exist."
        }
        return (Resolve-Path $Override).Path
    }

    $command = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $envPath = $env:SIGNTOOL_PATH
    if ($envPath -and (Test-Path $envPath)) {
        return (Resolve-Path $envPath).Path
    }

    $wellKnown = @(
        "C:\Program Files (x86)\Windows Kits\10\App Certification Kit\signtool.exe",
        "C:\Program Files (x86)\Windows Kits\10\bin\x64\signtool.exe",
        "C:\Program Files (x86)\Windows Kits\10\bin\x86\signtool.exe"
    )

    foreach ($candidate in $wellKnown) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    throw "signtool.exe not found on PATH, SIGNTOOL_PATH, or any well-known Windows SDK folders."
}

function Get-CodesignProfile {
    [CmdletBinding()]
    param(
        [psobject]$Metadata,
        [string]$Channel
    )

    if (-not $Metadata) { return $null }

    $codesign = $Metadata.workspace.metadata.dist.codesign
    if (-not $codesign) { return $null }

    if (-not $Channel -and $codesign.default_channel) {
        $Channel = $codesign.default_channel
    }
    if (-not $Channel) { return $null }

    $channels = $codesign.channels
    if (-not $channels) { return $null }

    foreach ($prop in $channels.PSObject.Properties) {
        if ($prop.Name -ieq $Channel) {
            return [pscustomobject]@{
                Name     = $prop.Name
                Settings = $prop.Value
            }
        }
    }

    return $null
}

function Get-SupplyChainPolicy {
    [CmdletBinding()]
    param(
        [psobject]$Metadata,
        [string]$Channel
    )

    if (-not $Metadata) { return $null }
    $supply = $Metadata.workspace.metadata.dist.supply_chain
    if (-not $supply) { return $null }

    $result = @{}
    foreach ($prop in $supply.PSObject.Properties) {
        if ($prop.Name -ne "channels") {
            $result[$prop.Name] = $prop.Value
        }
    }

    if ($Channel -and $supply.channels) {
        foreach ($prop in $supply.channels.PSObject.Properties) {
            if ($prop.Name -ieq $Channel) {
                foreach ($chanProp in $prop.Value.PSObject.Properties) {
                    $result[$chanProp.Name] = $chanProp.Value
                }
                break
            }
        }
    }

    return [pscustomobject]$result
}
