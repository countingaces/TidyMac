#!/usr/bin/env bash
# TidyMac release build pipeline.
#
# Builds a Release archive, exports a signed .app, packages it into a
# DMG, signs the DMG, submits it to Apple's notary service, and staples
# the resulting ticket. Output: build/TidyMac.dmg, ready to distribute.
#
# Configuration is environment-driven so this script can be the same
# whether you run it locally (with credentials in ~/.zshenv) or on
# GitHub Actions (with credentials in encrypted secrets):
#
#   TIDYMAC_TEAM_ID         — your Developer ID team (the OU value
#                             in your Developer ID Application cert).
#                             Required.
#   TIDYMAC_DEVELOPER_ID    — full identity name, e.g. "Developer ID
#                             Application: Your Name (TEAMID)".
#                             Required for codesign --sign.
#   TIDYMAC_APPLE_ID        — Apple ID email used for notarization.
#                             Required for notarytool submit.
#   TIDYMAC_NOTARY_PASSWORD — app-specific password for the Apple
#                             ID. Generate one at appleid.apple.com.
#                             Use "@keychain:NAME" to read from a
#                             keychain item set up via:
#                                 xcrun notarytool store-credentials
#                             Required for notarytool submit.
#
# Until you enrol in the Apple Developer Program ($99/year), every
# step that needs a real Developer ID will fail loudly. The xcodebuild
# archive step still works (you'll get an unsigned/ad-hoc-signed .app
# in build/release/) — useful for local smoke testing.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

PROJECT="TidyMac.xcodeproj"
SCHEME="TidyMac"
ARCHIVE_PATH="build/TidyMac.xcarchive"
EXPORT_DIR="build/release"
DMG_PATH="build/TidyMac.dmg"

: "${TIDYMAC_TEAM_ID:=PLACEHOLDER_TEAM_ID}"
: "${TIDYMAC_DEVELOPER_ID:=Developer ID Application: PLACEHOLDER (PLACEHOLDER_TEAM_ID)}"
: "${TIDYMAC_APPLE_ID:=placeholder@example.com}"
: "${TIDYMAC_NOTARY_PASSWORD:=@keychain:TIDYMAC_NOTARY_PASSWORD}"

mkdir -p build

echo "→ 1/6 archive"
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination 'generic/platform=macOS'

echo "→ 2/6 export signed app"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist ExportOptions.plist

APP_PATH="$EXPORT_DIR/TidyMac.app"

echo "→ 3/6 package DMG"
rm -f "$DMG_PATH"
hdiutil create \
    -volname "TidyMac" \
    -srcfolder "$APP_PATH" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

echo "→ 4/6 sign DMG"
codesign \
    --sign "$TIDYMAC_DEVELOPER_ID" \
    --timestamp \
    "$DMG_PATH"

echo "→ 5/6 notarize"
xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$TIDYMAC_APPLE_ID" \
    --team-id "$TIDYMAC_TEAM_ID" \
    --password "$TIDYMAC_NOTARY_PASSWORD" \
    --wait

echo "→ 6/6 staple"
xcrun stapler staple "$DMG_PATH"

echo
echo "✓ TidyMac.dmg ready at $DMG_PATH"
