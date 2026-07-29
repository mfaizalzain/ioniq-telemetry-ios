#!/bin/bash
#
# Archives a Release build and uploads it to TestFlight.
#
# Uses the Apple ID app-specific password stored in the macOS keychain
# (service: AC_PASSWORD, account: faizalmzain@gmail.com).
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

: "${AC_PASSWORD:?set AC_PASSWORD in keychain}"
echo "Checking AC_PASSWORD keychain entry..."
security find-generic-password -s "AC_PASSWORD" -a "faizalmzain@gmail.com" >/dev/null 2>&1 || {
  echo "Error: AC_PASSWORD not found in keychain."
  echo "Generate at appleid.apple.com/account/manage and run:"
  echo "  security add-generic-password -a faizalmzain@gmail.com -s AC_PASSWORD -w 'xxxx-xxxx-xxxx-xxxx'"
  exit 1
}

echo "==> Uploading to TestFlight"
xcrun altool --upload-app \
  -f "$BUILD_DIR/$SCHEME.ipa" \
  -t ios \
  -u faizalmzain@gmail.com \
  -p "@keychain:AC_PASSWORD"

echo "==> Done. Build $NEXT uploaded."
