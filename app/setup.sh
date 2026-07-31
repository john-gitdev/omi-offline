#!/bin/bash
#
# Set up the Omi Offline Mobile Project (Android).
#
# Prerequisites (stable versions, use these or higher):
#
# Common for all developers:
# - Flutter SDK (v3.35.3)
# - Opus Codec: https://opus-codec.org
#
# For Android Developers:
# - Android Studio (Iguana | 2024.3)
# - Android SDK Platform (API 36)
# - JDK (v21)
# - Gradle (v8.10)
# - NDK (28.2.13676358)
#
# Usages:
# - $bash setup.sh android
#
# iOS is not supported for now - see the "iOS support removed" section in NOTES.md
# for how the iOS build worked and how to restore it.

set -euo pipefail

echo "👋 Yo folks! Welcome to the Omi Offline Mobile Project - We're hiring! Join us on Discord: http://discord.omi.me"
echo "Prerequisites (stable versions, use these or higher):"
echo ""
echo "Common for all developers:"
echo "- Flutter SDK (v3.35.3)"
echo "- Opus Codec: https://opus-codec.org"
echo ""
echo "For Android Developers:"
echo "- Android Studio (Iguana | 2024.3)"
echo "- Android SDK Platform (API 36)"
echo "- JDK (v21)"
echo "- Gradle (v8.10)"
echo "- NDK (28.2.13676358)"
echo ""
echo "Usages:"
echo "- bash setup.sh android"
echo ""


API_BASE_URL=https://api.omiapi.com/

#################
# Set up App .env
#################
function setup_app_env() {
  echo "📝 Creating .dev.env..."
  echo "API_BASE_URL=$API_BASE_URL" > .dev.env
  echo "USE_WEB_AUTH=true" >> .dev.env
  echo "USE_AUTH_CUSTOM_TOKEN=true" >> .dev.env
}

# #######################
# Set up Android Keystore
# #######################
function setup_keystore_android() {
  echo "🔑 Setting up Android keystore..."
  cp setup/prebuilt/key.properties android/
}

# #####
# Build
# #####
function run_build_android() {
  echo "🚀 Building and running Android (dev flavor)..."
  flutter pub get \
    && dart run build_runner build --delete-conflicting-outputs \
    && flutter run --flavor dev
}

case "${1}" in
  android)
    setup_keystore_android \
      && setup_app_env \
      && run_build_android
    ;;
  *)
    echo "Error: unexpected platform '${1}'. Only 'android' is supported (iOS was removed - see NOTES.md)." >&2
    exit 1
    ;;
esac
