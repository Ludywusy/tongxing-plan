[CmdletBinding()]
param(
    [string]$StageRoot
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$mobileRoot = Join-Path $repoRoot 'mobile'

if ([string]::IsNullOrWhiteSpace($StageRoot)) {
    $StageRoot = Join-Path $env:TEMP 'tongxing-mobile-build'
}

$flutter = if ($env:TONGXING_FLUTTER) {
    $env:TONGXING_FLUTTER
} else {
    Join-Path $env:LOCALAPPDATA 'Temp\tongxing-flutter-sdk\bin\flutter.bat'
}

$androidSdk = if ($env:TONGXING_ANDROID_SDK) {
    $env:TONGXING_ANDROID_SDK
} else {
    Join-Path $env:LOCALAPPDATA 'Temp\tongxing-android-sdk'
}

if (!(Test-Path -LiteralPath $flutter)) {
    throw "Flutter SDK not found: $flutter. Set TONGXING_FLUTTER to flutter.bat."
}
if (!(Test-Path -LiteralPath $androidSdk)) {
    throw "Android SDK not found: $androidSdk. Set TONGXING_ANDROID_SDK to the SDK directory."
}

New-Item -ItemType Directory -Force -Path $StageRoot | Out-Null
robocopy $mobileRoot $StageRoot /E /XD build .dart_tool .idea android\.gradle /XF local.properties /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -gt 7) {
    throw "Could not stage the mobile project (robocopy exit code $LASTEXITCODE)."
}

@(
    "sdk.dir=$($androidSdk -replace '\\', '\\')"
    "flutter.sdk=$((Split-Path -Parent (Split-Path -Parent $flutter)) -replace '\\', '\\')"
) | Set-Content -LiteralPath (Join-Path $StageRoot 'android\local.properties') -Encoding ASCII

if ([string]::IsNullOrWhiteSpace($env:JAVA_TOOL_OPTIONS)) {
    $env:JAVA_TOOL_OPTIONS = '-Djdk.net.unixdomain.tmpdir=C:/nonexistent-codex-socket-dir'
}

& $flutter config --android-sdk=$androidSdk | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw 'Flutter could not select the Android SDK.'
}

Push-Location $StageRoot
try {
    & $flutter pub get
    if ($LASTEXITCODE -ne 0) {
        throw 'flutter pub get failed.'
    }

    & $flutter build apk --debug
    if ($LASTEXITCODE -ne 0) {
        throw 'flutter build apk --debug failed.'
    }
} finally {
    Pop-Location
}

$builtApk = Join-Path $StageRoot 'build\app\outputs\flutter-apk\app-debug.apk'
$deliveryDir = Join-Path $mobileRoot 'build\app\outputs\flutter-apk'
$deliveryApk = Join-Path $deliveryDir 'app-debug.apk'
if (!(Test-Path -LiteralPath $builtApk)) {
    throw "Build completed without an APK: $builtApk"
}

New-Item -ItemType Directory -Force -Path $deliveryDir | Out-Null
Copy-Item -LiteralPath $builtApk -Destination $deliveryApk -Force
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $deliveryApk).Hash
Write-Host "APK: $deliveryApk"
Write-Host "SHA256: $hash"
