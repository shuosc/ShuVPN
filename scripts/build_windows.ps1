param(
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture = ([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()),
    [switch]$SkipBuild
)

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

    $releaseDirectory = Join-Path $projectDirectory "build/windows/$Architecture/runner/Release"
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

    # Check the machine type of the executable and every bundled DLL. In
    # particular, an x64 Dart SDK on an ARM runner must never produce an ARM label.
    $expectedMachine = if ($Architecture -eq 'arm64') { 0xAA64 } else { 0x8664 }
    $nativeFiles = @(Get-ChildItem -LiteralPath $releaseDirectory -File | Where-Object {
        $_.Extension -in @('.exe', '.dll')
    })
    foreach ($nativeFile in $nativeFiles) {
        $reader = [System.IO.BinaryReader]::new([System.IO.File]::OpenRead($nativeFile.FullName))
        try {
            if ($reader.ReadUInt16() -ne 0x5A4D) { throw "Not a PE file: $($nativeFile.Name)" }
            $reader.BaseStream.Position = 0x3C
            $peOffset = $reader.ReadUInt32()
            $reader.BaseStream.Position = $peOffset
            if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne $expectedMachine) {
                throw "Architecture mismatch in $($nativeFile.Name), expected $Architecture."
            }
        } finally { $reader.Dispose() }
    }
    # Dart's Windows AOT snapshot uses ELF rather than PE.
    $snapshotReader = [System.IO.BinaryReader]::new([System.IO.File]::OpenRead((Join-Path $releaseDirectory 'data/app.so')))
    try {
        if ($snapshotReader.ReadUInt32() -ne 0x464C457F) { throw 'Invalid AOT snapshot.' }
        $snapshotReader.BaseStream.Position = 18
        $expectedElfMachine = if ($Architecture -eq 'arm64') { 183 } else { 62 }
        if ($snapshotReader.ReadUInt16() -ne $expectedElfMachine) { throw 'AOT snapshot architecture mismatch.' }
    } finally { $snapshotReader.Dispose() }
    $version = (Select-String -Path pubspec.yaml -Pattern '^version: ([^+]+)\+').Matches.Groups[1].Value
    if (-not $version) { throw 'Application version is missing.' }
    New-Item -ItemType Directory -Path 'build/release' -Force | Out-Null
    $archivePath = Join-Path $projectDirectory "build/release/ShuVPN-v$version-windows-$Architecture.zip"
    Compress-Archive -Path (Join-Path $releaseDirectory '*') -DestinationPath $archivePath -Force
    Write-Output "Runnable application: $(Join-Path $releaseDirectory 'shuvpn.exe')"
    Write-Output "Portable bundle: $archivePath"
} finally {
    Pop-Location
}
