#!/usr/bin/env bash
# Light-weight release script for unsigned distribution.
#
# Usage: ./Scripts/create-release.sh <version>
#   e.g. ./Scripts/create-release.sh 0.1.0
#
# Builds TidyMac in Release configuration, zips the resulting .app,
# and prints the next steps for tagging the commit and uploading the
# zip to a GitHub Release.
#
# This is the no-Developer-ID path. For a fully signed + notarized
# release, use Scripts/build-release.sh instead — that's the pipeline
# the GitHub Actions workflow drives once you've enrolled in the
# Apple Developer Program and added the cert/credentials secrets.
set -euo pipefail

VERSION="${1:?Usage: create-release.sh <version> (e.g. 0.1.0)}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

DERIVED="$ROOT_DIR/build"
ZIP_PATH="$ROOT_DIR/TidyMac-${VERSION}.zip"

echo "→ building TidyMac $VERSION"
xcodebuild \
    -project TidyMac.xcodeproj \
    -scheme TidyMac \
    -configuration Release \
    -derivedDataPath "$DERIVED" \
    build

APP_PATH="$DERIVED/Build/Products/Release/TidyMac.app"
if [ ! -d "$APP_PATH" ]; then
    echo "✗ Expected app at $APP_PATH but it isn't there. Build failed?" >&2
    exit 1
fi

echo "→ packaging $APP_PATH → $ZIP_PATH"
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

SHA=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')

cat <<EOF

✓ TidyMac-${VERSION}.zip ready

  SHA-256: ${SHA}

Next steps:

  git tag v${VERSION}
  git push origin v${VERSION}

  gh release create v${VERSION} TidyMac-${VERSION}.zip \\
      --title "TidyMac ${VERSION}" \\
      --notes-file RELEASE_NOTES.md

Then update Casks/tidymac.rb in your homebrew-tap repo:
  - version "${VERSION}"
  - sha256 "${SHA}"

EOF
