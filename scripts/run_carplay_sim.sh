#!/bin/bash
#
# Builds and installs the app in the simulator with the CarPlay entitlement, then
# opens the Simulator so you can attach the CarPlay display.
#
# Simulator builds skip provisioning-profile validation, so this works before
# Apple grants com.apple.developer.carplay-charging.
#
# The entitlement comes from the Debug-CarPlay build configuration, not from a
# CODE_SIGN_ENTITLEMENTS override on the command line: that override leaks into
# every SPM package target (they resolve the relative path against their own
# directory and fail to build), and even with an absolute path the app target's
# own setting still wins, so the app silently builds with empty entitlements and
# the CarPlay scene never attaches.
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
  -configuration Debug-CarPlay \
  -destination "id=$SIM_ID" \
  -derivedDataPath build/carplay \
  build | grep -E 'error:|BUILD' || true

APP="build/carplay/Build/Products/Debug-CarPlay-iphonesimulator/IoniqTelemetry.app"
if [[ ! -d "$APP" ]]; then
  echo "Build did not produce $APP" >&2
  exit 1
fi

# Prove the entitlement actually made it in — an app without it installs and runs
# fine, it just never appears on the CarPlay screen, which is a confusing way to
# spend an afternoon.
XCENT="build/carplay/Build/Intermediates.noindex/IoniqTelemetry.build/Debug-CarPlay-iphonesimulator/IoniqTelemetry.build/IoniqTelemetry.app-Simulated.xcent"
if grep -q "carplay-charging" "$XCENT" 2>/dev/null; then
  echo "==> CarPlay entitlement present"
else
  echo "==> WARNING: CarPlay entitlement missing from $XCENT" >&2
fi

xcrun simctl install "$SIM_ID" "$APP"
xcrun simctl launch "$SIM_ID" com.fmz.IoniqTelemetry

echo
echo "Now in the Simulator menu: I/O > External Displays > CarPlay"
echo "The app appears on the CarPlay home screen; tap its icon to open it."
