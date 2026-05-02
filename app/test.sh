#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

# Ensure environment is ready
if [[ ! -f ".dev.env" ]]; then
  echo "📝 Creating .dev.env..."
  echo "API_BASE_URL=https://api.omiapi.com/" > .dev.env
  echo "USE_AUTH_CUSTOM_TOKEN=true" >> .dev.env
  echo "STAGING_API_URL=" >> .dev.env
fi

echo "📦 Ensuring dependencies and generated files are up to date..."
flutter pub get
dart run build_runner build --delete-conflicting-outputs

echo "🧪 Running unit tests..."
flutter test test/unit/
