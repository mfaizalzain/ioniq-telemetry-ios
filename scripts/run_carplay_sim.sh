#!/bin/bash
#
# Runs the app in the simulator with the CarPlay entitlement and opens the
# CarPlay display. Simulator builds skip provisioning-profile validation, so this
# works before Apple grants the entitlement.
#
# After it launches, in the Simulator app choose:
#   I/O > External Displays > CarPlay
set -euo pipefail
cd "$(dirname "$0")/.."

SIM_NAME="${1:-iPhone 17 Pro}"
SIM_ID=$(xcrun simctl list devices available \
  | awk -v n="$SIM_NAME" -F'[()]' '$0 ~ n"[ ]*\\(" {print $2; exit}')

if [[ -z "$SIM_ID" ]]; then
  echo "No simulator named '$SIM_NAME'." >&2
  exit 1
fi

xcrun simctl boot "$SIM_ID" 2>/dev/null || true
open -a Simulator

xcodegen generate
xcodebuild \
  -project IoniqTelemetry.xcodeproj \
  -scheme IoniqTelemetry \
  -configuration Debug \
  -destination "id=$SIM_ID" \
  -derivedDataPath build/carplay \
  CODE_SIGN_ENTITLEMENTS="IoniqTelemetry/Resources/IoniqTelemetry-CarPlay.entitlements" \
  build | grep -E 'error:|BUILD' || true

APP="build/carplay/Build/Products/Debug-iphonesimulator/IoniqTelemetry.app"
xcrun simctl install "$SIM_ID" "$APP"
xcrun simctl launch "$SIM_ID" com.fmz.IoniqTelemetry

echo
echo "Now in the Simulator menu: I/O > External Displays > CarPlay"
