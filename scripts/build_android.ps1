param(
    [ValidateSet('arm64-v8a', 'armeabi-v7a', 'x86_64', 'universal')]
    [string]$Architecture = 'arm64-v8a',
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$projectDirectory = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $projectDirectory
try {
    $versionLine = (Select-String -Path pubspec.yaml -Pattern '^version: (.+)$').Matches.Groups[1].Value
    if ($versionLine -notmatch '^([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?)\+([0-9]+)$') {
        throw 'Invalid application version.'
    }
    $versionName = $Matches[1]
    $buildNumber = $Matches[2]
    $targets = @{
        'arm64-v8a' = 'android-arm64'
        'armeabi-v7a' = 'android-arm'
        'x86_64' = 'android-x64'
        'universal' = 'android-arm,android-arm64,android-x64'
    }
    if (-not $SkipBuild) {
        $buildArgs = @('build', 'apk', '--release', '--target-platform', $targets[$Architecture],
            '--build-name', $versionName, '--build-number', $buildNumber,
            '-Pforce-version-code-ignoring-abi=true')
        if ($Architecture -ne 'universal') { $buildArgs += '--split-per-abi' }
        & flutter @buildArgs
        if ($LASTEXITCODE -ne 0) { throw "Android build failed (exit code $LASTEXITCODE)." }
    }
    $sourceName = if ($Architecture -eq 'universal') { 'app-release.apk' } else { "app-$Architecture-release.apk" }
    $sourcePath = Join-Path 'build/app/outputs/flutter-apk' $sourceName
    $expectedAbis = if ($Architecture -eq 'universal') { @('armeabi-v7a', 'arm64-v8a', 'x86_64') } else { @($Architecture) }
    $archive = [System.IO.Compression.ZipFile]::OpenRead((Join-Path $projectDirectory $sourcePath))
    try {
        $entries = @($archive.Entries.FullName)
        $actualAbis = @($entries | Where-Object { $_ -match '^lib/[^/]+/[^/]+\.so$' } |
            ForEach-Object { ($_ -split '/')[1] } | Sort-Object -Unique)
        if (Compare-Object ($expectedAbis | Sort-Object) $actualAbis) { throw 'Unexpected APK native architectures.' }
        foreach ($abi in $expectedAbis) {
            foreach ($library in @('libapp.so', 'libflutter.so')) {
                if ($entries -notcontains "lib/$abi/$library") { throw "Missing $abi/$library in APK." }
            }
        }
    } finally { $archive.Dispose() }
    New-Item -ItemType Directory -Path 'build/release' -Force | Out-Null
    $destination = "build/release/ShuVPN-v$versionName-android-$Architecture.apk"
    Copy-Item -LiteralPath $sourcePath -Destination $destination -Force
    Write-Output "Release APK: $destination"
} finally { Pop-Location }
