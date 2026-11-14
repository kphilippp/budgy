#!/bin/zsh
# Archive Budgy (Release) and upload it to TestFlight.
#
#   scripts/testflight.sh
#
# Needs scripts/testflight.env (never committed; copy testflight.env.example) with your
# App Store Connect API key's ASC_KEY_ID and ASC_ISSUER_ID, and the key file at
# ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8. The key needs the Admin role
# so Xcode can use Apple's cloud-managed distribution certificate.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

ENV_FILE="$ROOT/scripts/testflight.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "✗ Missing scripts/testflight.env. Copy scripts/testflight.env.example and fill in your key's IDs."
  exit 1
fi
source "$ENV_FILE"
: "${ASC_KEY_ID:?Set ASC_KEY_ID in scripts/testflight.env}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID in scripts/testflight.env}"
KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
if [[ ! -f "$KEY_PATH" ]]; then
  echo "✗ Can't find the API key file at $KEY_PATH."
  exit 1
fi

# Build numbers only go up: the UTC date, then hours and minutes, like 20261114.315 for 03:15.
# (10# drops leading zeros, which App Store validation can reject.)
NOW=$(date -u +%Y%m%d%H%M)
BUILD_NUMBER="${NOW[1,8]}.$((10#${NOW[9,12]}))"
VERSION=$(grep -o '"MARKETING_VERSION": "[^"]*"' budgy.xcodeproj/project.xcproj | head -1 | cut -d'"' -f4)
ARCHIVE="$ROOT/build/archives/budgy-$BUILD_NUMBER.xcarchive"
EXPORT_DIR="$ROOT/build/export/$BUILD_NUMBER"

# Only the key's path and IDs are passed; its contents are never read or printed here.
AUTH=(
  -allowProvisioningUpdates
  -authenticationKeyPath "$KEY_PATH"
  -authenticationKeyID "$ASC_KEY_ID"
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
)

echo "▸ Archiving Budgy $VERSION ($BUILD_NUMBER), Release…"
xcodebuild -project budgy.xcodeproj -scheme budgy -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  "${AUTH[@]}" \
  archive -quiet

echo "▸ Signing and uploading to App Store Connect…"
# Hide the per-percent upload progress lines; errors and the final status still show.
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$ROOT/scripts/ExportOptions.plist" \
  "${AUTH[@]}" \
  -quiet 2>&1 | { grep -v -E 'Progress [0-9]+%' || true; }

echo "✓ Uploaded Budgy $VERSION ($BUILD_NUMBER)."
echo "  Apple processes it for a few minutes, then it appears in TestFlight for your testers."
