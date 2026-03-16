# Set up the Omi Mobile Project(iOS/Android).
#
# Prerequisites (stable versions, use these or higher):
#
# Common for all developers:
# - Flutter SDK (v3.35.3)
# - Opus Codec: https://opus-codec.org
#
# For iOS Developers:
# - Xcode (v16.4)
# - CocoaPods (v1.16.2)
#
# For Android Developers:
# - Android Studio (Iguana | 2024.3)
# - Android SDK Platform (API 36)
# - JDK (v21)
# - Gradle (v8.10)
# - NDK (28.2.13676358)

# Enable strict mode
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Write-Host "👋 Yo folks! Welcome to the OMI Mobile Project - We're hiring! Join us on Discord: http://discord.omi.me"
Write-Host "Prerequisites (stable versions, use these or higher):"
Write-Host ""
Write-Host "Common for all developers:"
Write-Host "- Flutter SDK (v3.35.3)"
Write-Host "- Opus Codec: https://opus-codec.org"
Write-Host ""
Write-Host "For iOS Developers:"
Write-Host "- Xcode (v16.4)"
Write-Host "- CocoaPods (v1.16.2)"
Write-Host ""
Write-Host "For Android Developers:"
Write-Host "- Android Studio (Iguana | 2024.3)"
Write-Host "- Android SDK Platform (API 36)"
Write-Host "- JDK (v21)"
Write-Host "- Gradle (v8.10)"
Write-Host "- NDK (28.2.13676358)"
Write-Host ""



function SetupProvisioningProfile {
    # Check if fastlane exists
    if (!(Get-Command "fastlane" -ErrorAction SilentlyContinue)) {
        Write-Host "Installing fastlane..."
        brew install fastlane
    }
    
    $env:MATCH_PASSWORD = "omi"
    fastlane match development --readonly `
        --app_identifier "com.omi.offline.development" `
        --git_url "git@github.com:BasedHardware/omi-community-certs.git"
}


function SetupAppEnv {
    $API_BASE_URL = "https://api.omiapi.com/"
    # Using Set-Content with UTF8 encoding
    $content = "API_BASE_URL=$API_BASE_URL"
    [System.IO.File]::WriteAllText((Join-Path (Get-Location) ".dev.env"), $content, [System.Text.Encoding]::UTF8)
}

function SetupKeystoreAndroid {
    Copy-Item "setup/prebuilt/key.properties" -Destination "android/"
}

function Build {
    flutter pub get
    dart run build_runner build
}

function BuildiOS {
    flutter pub get
    Push-Location "ios"
    pod install --repo-update
    Pop-Location
    dart run build_runner build
}

function RunDev {
    flutter run --flavor dev
}

# Function to show menu and get platform choice
function Show-PlatformMenu {
    Write-Host "`nSelect platform to setup:"
    Write-Host "1. iOS"
    Write-Host "2. Android"
    Write-Host "3. Exit"
    
    $choice = Read-Host "`nEnter your choice (1-3)"
    
    switch ($choice) {
        "1" { return "ios" }
        "2" { return "android" }
        "3" { exit 0 }
        default { 
            Write-Host "Invalid choice. Please try again."
            return Show-PlatformMenu
        }
    }
}

# Get platform from argument or menu
$platform = if ($args.Count -eq 0) {
    Show-PlatformMenu
} else {
    $args[0]
}

# Replace the existing switch block with this:
switch ($platform.ToLower()) {
    "ios" {
        Write-Host "`nSetting up iOS platform..."
        SetupAppEnv
        SetupProvisioningProfile
        BuildiOS
    }
    "android" {
        Write-Host "`nSetting up Android platform..."
        SetupKeystoreAndroid
        SetupAppEnv
        Build
    }
    default {
        Write-Host "Unexpected platform '$platform'. Please use 'ios' or 'android'"
        exit 1
    }
} 
