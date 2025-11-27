param(
    [Parameter(Mandatory = $true)][string]$ArtifactsDir,
    [Parameter(Mandatory = $true)][string]$BinaryDir,
    [Parameter(Mandatory = $true)][string]$PfxBase64,
    [Parameter(Mandatory = $true)][string]$PfxPassword,
    [string]$TimestampUrl = "http://timestamp.digicert.com"
)

if (-not (Get-Command signtool.exe -ErrorAction SilentlyContinue)) {
    throw "signtool.exe not found on PATH. Install the Windows SDK or Visual Studio build tools to provide it."
}

$tempPfx = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("codesign-" + [guid]::NewGuid().ToString() + ".pfx")
[System.IO.File]::WriteAllBytes($tempPfx, [Convert]::FromBase64String($PfxBase64))

function Sign-File([string]$PathToFile) {
    param(
        [string]$CertificatePath,
        [string]$Password,
        [string]$Timestamp
    )
    Write-Host "Signing $PathToFile"
    & signtool.exe sign `
        /fd SHA256 `
        /td SHA256 `
        /tr $Timestamp `
        /f $CertificatePath `
        /p $Password `
        "$PathToFile"
    if ($LASTEXITCODE -ne 0) {
        throw "signtool failed for $PathToFile"
    }
}

function Sign-ExecutablesInTree([string]$Root) {
    param(
        [string]$CertificatePath,
        [string]$Password,
        [string]$Timestamp
    )
    if (-not (Test-Path $Root)) {
        return
    }
    Get-ChildItem -Path $Root -Filter *.exe -File -Recurse | ForEach-Object {
        Sign-File -PathToFile $_.FullName -CertificatePath $CertificatePath -Password $Password -Timestamp $Timestamp
    }
}

try {
    Sign-ExecutablesInTree -Root $BinaryDir -CertificatePath $tempPfx -Password $PfxPassword -Timestamp $TimestampUrl

    if (Test-Path $ArtifactsDir) {
        Get-ChildItem -Path $ArtifactsDir -Filter *.msi -File -Recurse | ForEach-Object {
            Sign-File -PathToFile $_.FullName -CertificatePath $tempPfx -Password $PfxPassword -Timestamp $TimestampUrl
        }

        Get-ChildItem -Path $ArtifactsDir -Filter *.zip -File | ForEach-Object {
            $zipPath = $_.FullName
            $extractDir = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ([guid]::NewGuid().ToString())
            Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force
            Sign-ExecutablesInTree -Root $extractDir -CertificatePath $tempPfx -Password $PfxPassword -Timestamp $TimestampUrl
            Remove-Item -LiteralPath $zipPath
            Compress-Archive -Path (Join-Path $extractDir '*') -DestinationPath $zipPath -Force
            Remove-Item -LiteralPath $extractDir -Recurse -Force
        }
    }
}
finally {
    if (Test-Path $tempPfx) {
        Remove-Item -LiteralPath $tempPfx -Force
    }
}
