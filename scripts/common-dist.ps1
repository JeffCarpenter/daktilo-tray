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
        [psobject]$Metadata
    )

    if (-not $Metadata) { return $null }
    return $Metadata.workspace.metadata.dist.supply_chain
}

