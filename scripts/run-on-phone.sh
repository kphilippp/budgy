#!/bin/zsh
# Build Budgy, install it on your iPhone, and launch it — the terminal version of Xcode's ⌘R.
#
#   scripts/run-on-phone.sh            build + install + launch
#   scripts/run-on-phone.sh --no-build reinstall/relaunch the last build
#
# Override the phone with DEVICE_ID=<udid> (list them with: xcrun devicectl list devices).
set -euo pipefail

DEVICE_ID="${DEVICE_ID:-00008160-00100D0236C00036}"
BUNDLE_ID="com.kevinphilip.budgy"
ROOT="${0:A:h:h}"
DERIVED="$ROOT/build/device"
APP="$DERIVED/Build/Products/Debug-iphoneos/budgy.app"

cd "$ROOT"

echo "▸ Checking the phone is reachable…"
STATE=$(xcrun devicectl list devices 2>/dev/null | grep "$DEVICE_ID" | grep -oE "available \(paired\)|connected|unavailable" | head -1 || true)
if [[ -z "$STATE" || "$STATE" == "unavailable" ]]; then
  echo "✗ Can't reach the phone ($DEVICE_ID)."
  echo "  Plug it in (or unlock it on the same Wi-Fi), make sure Developer Mode is on,"
  echo "  and tap Trust if it asks. Then run this again."
  exit 1
fi

if [[ "${1:-}" != "--no-build" ]]; then
  echo "▸ Building for device…"
  xcodebuild -project budgy.xcodeproj -scheme budgy -configuration Debug \
    -destination "id=$DEVICE_ID" \
    -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates \
    build -quiet
fi

echo "▸ Installing…"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP" >/dev/null

echo "▸ Launching…"
# --terminate-existing relaunches if Budgy is already open, so you always get the fresh build.
if ! LAUNCH_LOG=$(xcrun devicectl device process launch --device "$DEVICE_ID" --terminate-existing "$BUNDLE_ID" 2>&1); then
  if [[ "$LAUNCH_LOG" == *"explicitly trusted"* || "$LAUNCH_LOG" == *"Security"* ]]; then
    echo "✗ Installed, but iOS blocked the launch: your developer profile isn't trusted on this phone"
    echo "  (this resets when you delete every app you've signed)."
    echo "  On the phone: Settings → General → VPN & Device Management → Developer App → Trust."
    echo "  Then run this again with --no-build, or just open Budgy."
  elif [[ "$LAUNCH_LOG" == *"Locked"* || "$LAUNCH_LOG" == *"locked"* ]]; then
    echo "✗ Installed, but the phone is locked. Unlock it and open Budgy."
  else
    echo "$LAUNCH_LOG"
  fi
  exit 1
fi

echo "✓ Budgy is running on your phone."
