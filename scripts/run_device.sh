#!/bin/bash
#
# Build, install and launch on a connected iPhone.
#
#   scripts/run_device.sh              # normal build (installs today)
#   scripts/run_device.sh --carplay    # include the CarPlay entitlement
#
# --carplay only signs once Apple has granted com.apple.developer.carplay-charging
# and it is enabled on the App ID. Without that it fails with a provisioning error;
# use the CarPlay Simulator instead until then (see scripts/run_carplay_sim.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

ENTITLEMENTS="IoniqTelemetry/Resources/IoniqTelemetry.entitlements"
if [[ "${1:-}" == "--carplay" ]]; then
  ENTITLEMENTS="IoniqTelemetry/Resources/IoniqTelemetry-CarPlay.entitlements"
  echo "==> Including CarPlay entitlement"
fi

DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null \
  | awk '/physical/ && /iPhone/ {print $(NF-3); exit}')

if [[ -z "$DEVICE_ID" ]]; then
  echo "No iPhone found. Connect it, unlock it, and trust this Mac." >&2
  exit 1
fi
echo "==> Device $DEVICE_ID"

xcodegen generate

xcodebuild \
  -project IoniqTelemetry.xcodeproj \
  -scheme IoniqTelemetry \
  -configuration Debug \
  -destination "id=$DEVICE_ID" \
  -derivedDataPath build/device \
  -allowProvisioningUpdates \
  CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS" \
  build | grep -E 'error:|BUILD' || true

APP="build/device/Build/Products/Debug-iphoneos/IoniqTelemetry.app"
[[ -d "$APP" ]] || { echo "Build produced no app bundle." >&2; exit 1; }

echo "==> Installing"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP"

echo "==> Launching"
xcrun devicectl device process launch --device "$DEVICE_ID" com.fmz.IoniqTelemetry
