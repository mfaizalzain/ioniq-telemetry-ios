#!/bin/bash
#
# Archives a Release build and uploads it to TestFlight.
#
# Uploads with an App Store Connect API key: the .p8 must live at
# ~/private_keys/AuthKey_<keyid>.p8 and ASC_API_KEY_ID / ASC_API_ISSUER must be
# set (export them in your shell profile).
#
# Usage: scripts/archive_and_upload.sh [--no-upload]
set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="IoniqTelemetry"
PROJECT="IoniqTelemetry.xcodeproj"
BUILD_DIR="build/release"
ARCHIVE="$BUILD_DIR/$SCHEME.xcarchive"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found. Install with: brew install xcodegen" >&2
  exit 1
fi

echo "==> Regenerating project"
xcodegen generate

echo "==> Bumping build number"
# CURRENT_PROJECT_VERSION lives in project.yml, so agvtool would be overwritten
# on the next xcodegen run. Bump the source of truth instead.
CURRENT=$(grep -E '^\s+CURRENT_PROJECT_VERSION:' project.yml | sed -E 's/.*"([0-9]+)".*/\1/')
NEXT=$((CURRENT + 1))
sed -i '' -E "s/(CURRENT_PROJECT_VERSION: )\"[0-9]+\"/\1\"$NEXT\"/" project.yml
xcodegen generate
echo "    build $CURRENT -> $NEXT"

echo "==> Running tests"
swift test --package-path Packages/CoreOBD
swift test --package-path Packages/CoreDomain

echo "==> Archiving"
rm -rf "$ARCHIVE"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  | grep -E 'error:|warning:|BUILD' || true

if [[ ! -d "$ARCHIVE" ]]; then
  echo "Archive failed." >&2
  exit 1
fi

echo "==> Exporting IPA"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$BUILD_DIR" \
  -exportOptionsPlist scripts/ExportOptions.plist

if [[ "${1:-}" == "--no-upload" ]]; then
  echo "==> Skipping upload (--no-upload). IPA at $BUILD_DIR"
  exit 0
fi

: "${ASC_API_KEY_ID:?set ASC_API_KEY_ID (App Store Connect API key ID)}"
: "${ASC_API_ISSUER:?set ASC_API_ISSUER (App Store Connect issuer ID)}"
KEY_FILE="$HOME/private_keys/AuthKey_${ASC_API_KEY_ID}.p8"
echo "Checking API key at $KEY_FILE..."
[[ -f "$KEY_FILE" ]] || {
  echo "Error: $KEY_FILE not found."
  echo "Download the .p8 from App Store Connect (Users and Access > Integrations)"
  echo "and save it as $KEY_FILE, then re-run."
  exit 1
}

echo "==> Uploading to TestFlight"
xcrun altool --upload-app \
  -f "$BUILD_DIR/$SCHEME.ipa" \
  -t ios \
  --apiKey "$ASC_API_KEY_ID" \
  --apiIssuer "$ASC_API_ISSUER"

echo "==> Done. Build $NEXT uploaded."
