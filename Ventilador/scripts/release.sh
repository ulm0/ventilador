#!/bin/bash
# Builds a distributable Ventilador.zip, and (unless --skip-notarize) notarizes and staples it.
#
#   scripts/release.sh <version> [--skip-notarize]
#
# Needs (see RELEASING.md): a "Developer ID Application" identity in the keychain, the DEVELOPMENT_TEAM
# environment variable, and a notarytool keychain profile (NOTARY_PROFILE, default "ventilador-notary").
# For a dry run without those, use SIGN_IDENTITY="Apple Development" and --skip-notarize.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release.sh <version> [--skip-notarize]}"
SKIP_NOTARIZE=false
[ "${2:-}" = "--skip-notarize" ] && SKIP_NOTARIZE=true
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must look like 1.2.3" >&2; exit 1; }
: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to your Apple Team ID}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-ventilador-notary}"
# A distributable build needs Apple's secure timestamp; a dry run doesn't, and works offline.
$SKIP_NOTARIZE && TIMESTAMP="--timestamp=none" || TIMESTAMP="--timestamp"
BUILD=1   # bump CURRENT_PROJECT_VERSION here if you ever ship two builds of one version

OUT="dist"
PRODUCTS="build/release-products"
rm -rf "$OUT" "$PRODUCTS"
mkdir -p "$OUT"

xcodegen generate --quiet
xcodebuild build \
  -project Ventilador.xcodeproj -scheme Ventilador -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData SYMROOT="$PWD/$PRODUCTS" OBJROOT="$PWD/build/release-intermediates" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  OTHER_CODE_SIGN_FLAGS="$TIMESTAMP" MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  | grep -E "^\*\* BUILD|: error: " || true

APP="$PRODUCTS/Release/Ventilador.app"
[ -d "$APP" ] || { echo "build failed: $APP missing" >&2; exit 1; }

# The helper runs as root, so it must carry the same team signature and hardened runtime as the app.
codesign --verify --deep --strict "$APP"
for target in "$APP" "$APP/Contents/MacOS/com.ulm0.ventilador.helper"; do
  info="$(codesign -dv "$target" 2>&1)"
  grep -q "TeamIdentifier=$DEVELOPMENT_TEAM" <<<"$info" || { echo "$target: wrong or missing team" >&2; exit 1; }
  grep -q "flags=0x10000(runtime)" <<<"$info" || { echo "$target: hardened runtime is off" >&2; exit 1; }
done
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$VERSION" ] \
  || { echo "version not applied to Info.plist" >&2; exit 1; }

ZIP="$OUT/Ventilador-$VERSION.zip"
ditto -c -k --keepParent --norsrc --noextattr --noqtn "$APP" "$ZIP"

if $SKIP_NOTARIZE; then
  echo "skipping notarization: this zip is NOT distributable (Gatekeeper will reject it)"
else
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
  rm "$ZIP"
  ditto -c -k --keepParent --norsrc --noextattr --noqtn "$APP" "$ZIP"      # re-zip so the notarization ticket ships inside
fi

SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
cat > "$OUT/ventilador.rb" <<CASK
cask "ventilador" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/ulm0/ventilador/releases/download/v#{version}/Ventilador-#{version}.zip"
  name "Ventilador"
  desc "Fan control for Apple Silicon Macs"
  homepage "https://github.com/ulm0/ventilador"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Ventilador.app"

  # Stopping the helper returns any manually controlled fans to automatic before it exits.
  uninstall launchctl: "com.ulm0.ventilador.helper",
            quit:      "com.ulm0.ventilador"

  zap trash: [
    "~/Library/Application Support/Ventilador",
    "~/Library/Preferences/com.ulm0.ventilador.plist",
  ]
end
CASK

echo
echo "zip:    $ZIP"
echo "sha256: $SHA"
echo "cask:   $OUT/ventilador.rb  (copy to Casks/ventilador.rb in your homebrew-tap repo)"
