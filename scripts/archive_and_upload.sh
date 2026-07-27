#!/bin/bash
#
# Archives a Release build and uploads it to TestFlight.
#
# Requires an App Store Connect API key in the environment:
#   ASC_KEY_ID, ASC_ISSUER_ID, and ASC_KEY_PATH (path to the .p8).
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

: "${ASC_KEY_ID:?set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"
: "${ASC_KEY_PATH:?set ASC_KEY_PATH}"

echo "==> Uploading to TestFlight"
xcrun altool --upload-app \
  --type ios \
  --file "$BUILD_DIR/$SCHEME.ipa" \
  --apiKey "$ASC_KEY_ID" \
  --apiIssuer "$ASC_ISSUER_ID"

echo "==> Done. Build $NEXT uploaded."
