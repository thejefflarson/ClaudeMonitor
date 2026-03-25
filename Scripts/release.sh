#!/usr/bin/env bash
# release.sh — build, sign, notarize, and publish a ClaudeMonitor release locally.
#
# Usage:
#   ./Scripts/release.sh v1.5.0
#
# One-time credential setup (stores credentials in your login keychain):
#   xcrun notarytool store-credentials "ClaudeMonitorNotarization" \
#     --apple-id "you@example.com" \
#     --team-id "ABCDEF1234" \
#     --password "xxxx-xxxx-xxxx-xxxx"   # app-specific password from appleid.apple.com
#
# Optional environment variables:
#   NOTARYTOOL_PROFILE   keychain profile name (default: ClaudeMonitorNotarization)
#   DEVELOPMENT_TEAM     10-char Apple team ID (default: 2PR729W8E3)

set -euo pipefail

VERSION="${1:?Usage: $0 <version tag>  e.g. $0 v1.5.0}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d)"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-ClaudeMonitorNotarization}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-2PR729W8E3}"
APP_NAME="ClaudeMonitor"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

trap 'rm -rf "$BUILD_DIR"' EXIT

# ── Prerequisites ─────────────────────────────────────────────────────────────

for cmd in xcodegen xcodebuild xcrun hdiutil gh git; do
    command -v "$cmd" &>/dev/null || { echo "error: $cmd not found"; exit 1; }
done

IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null)
if [[ "$IDENTITIES" != *"Developer ID Application"* ]]; then
    echo "error: no 'Developer ID Application' certificate found in keychain"
    exit 1
fi

if git tag --list | grep -qxF "$VERSION"; then
    echo "error: tag $VERSION already exists locally"
    exit 1
fi

if git status --porcelain | grep -q .; then
    echo "error: working tree is dirty — commit or stash changes before releasing"
    exit 1
fi

echo "releasing $APP_NAME $VERSION"

# ── Generate & archive ────────────────────────────────────────────────────────

cd "$REPO_ROOT"
echo "→ generating Xcode project"
xcodegen generate --quiet

echo "→ building archive (Release)"
xcodebuild archive \
    -scheme "$APP_NAME" \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    -quiet

# ── Export ────────────────────────────────────────────────────────────────────

echo "→ copying app from archive"
mkdir -p "$EXPORT_DIR"
cp -R "$ARCHIVE/Products/Applications/$APP_NAME.app" "$EXPORT_DIR/"

# ── DMG ───────────────────────────────────────────────────────────────────────

echo "→ creating DMG"
DMG_STAGING="$BUILD_DIR/dmg-staging"
mkdir -p "$DMG_STAGING"
cp -R "$EXPORT_DIR/$APP_NAME.app" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$DMG" \
    > /dev/null

# ── Notarize & staple ─────────────────────────────────────────────────────────

echo "→ notarizing (~2 min)"
xcrun notarytool submit "$DMG" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait

echo "→ stapling"
xcrun stapler staple "$DMG"

# ── Tag & publish ─────────────────────────────────────────────────────────────

echo "→ pushing main and tagging $VERSION"
git push origin main
git tag "$VERSION"
git push origin "$VERSION"

echo "→ creating GitHub release"
gh release create "$VERSION" "$DMG" \
    --title "$APP_NAME $VERSION" \
    --generate-notes

echo "done — $APP_NAME $VERSION released"
