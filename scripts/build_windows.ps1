param([switch]$SkipBuild)

$ErrorActionPreference = 'Stop'
$projectDirectory = Split-Path -Parent $PSScriptRoot

Push-Location -LiteralPath $projectDirectory
try {
    if (-not $SkipBuild) {
        & flutter build windows --release
        if ($LASTEXITCODE -ne 0) {
            throw "Windows build failed (exit code $LASTEXITCODE)."
        }
    }

    $releaseDirectory = Join-Path $projectDirectory 'build/windows/x64/runner/Release'
    foreach ($requiredFile in @(
        'shuvpn.exe', 'flutter_windows.dll', 'msvcp140.dll',
        'vcruntime140.dll', 'vcruntime140_1.dll',
        'flutter_sangfor_plugin.dll', 'url_launcher_windows_plugin.dll',
        'data/app.so', 'data/icudtl.dat', 'data/flutter_assets/NOTICES.Z',
        'data/license.windows_flutter.md', 'LICENSE'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $releaseDirectory $requiredFile))) {
            throw "Missing bundle file: $requiredFile. Run without -SkipBuild first."
        }
    }

    $archivePath = Join-Path $projectDirectory 'build/windows/ShuVPN-windows-x64.zip'
    Compress-Archive -Path (Join-Path $releaseDirectory '*') -DestinationPath $archivePath -Force
    $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    "$archiveHash  $(Split-Path -Leaf $archivePath)" | Set-Content -LiteralPath "$archivePath.sha256" -Encoding ascii
    Write-Output "Runnable application: $(Join-Path $releaseDirectory 'shuvpn.exe')"
    Write-Output "Portable bundle: $archivePath"
} finally {
    Pop-Location
}
