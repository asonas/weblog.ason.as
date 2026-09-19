$ErrorActionPreference = "Stop"

if (-not $env:ANDROID_HOME) {
    throw "ANDROID_HOME is not set. Run this script through mise run setup:android."
}

$packages = @(
    @{ Name = "platform-tools"; Path = "platform-tools\adb.exe" },
    @{ Name = "platforms/android-35"; Path = "platforms\android-35\android.jar" },
    @{ Name = "build-tools/34.0.0"; Path = "build-tools\34.0.0\aapt2.exe" }
)

foreach ($package in $packages) {
    $installedPath = Join-Path $env:ANDROID_HOME $package.Path
    if (Test-Path -LiteralPath $installedPath) {
        Write-Host "$($package.Name) is already installed."
        continue
    }

    & android sdk install $package.Name
    if (-not (Test-Path -LiteralPath $installedPath)) {
        throw "Android SDK package installation failed: $($package.Name)"
    }
}

Write-Host "Android SDK setup is complete."
