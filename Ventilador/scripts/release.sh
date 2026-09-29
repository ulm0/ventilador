#!/bin/bash
# Produces a distributable Ventilador zip and the Homebrew cask.
#
#   scripts/release.sh <version> [--skip-notarize]      build, sign, notarize and package
#   scripts/release.sh --package-only <Ventilador.app> [--allow-unnotarized]
#                                                        package an app you archived and exported
#                                                        (notarized) from Xcode
#
# Needs (see RELEASING.md): the DEVELOPMENT_TEAM environment variable. The first form also needs a
# "Developer ID Application" identity in the keychain and a notarytool keychain profile (NOTARY_PROFILE,
# default "ventilador-notary"). For a dry run without them use SIGN_IDENTITY="Apple Development" and
# --skip-notarize (first form) or --allow-unnotarized (second form).
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to your Apple Team ID}"
OUT="dist"
PRODUCTS="build/release-products"
NOTARY_PROFILE="${NOTARY_PROFILE:-ventilador-notary}"
PACKAGE_ONLY=false
SKIP_NOTARIZE=false

if [ "${1:-}" = "--package-only" ]; then
  PACKAGE_ONLY=true
  APP="${2:?usage: scripts/release.sh --package-only <Ventilador.app> [--allow-unnotarized]}"
  [ -d "$APP" ] || { echo "not an app bundle: $APP" >&2; exit 1; }
  [ "${3:-}" = "--allow-unnotarized" ] && SKIP_NOTARIZE=true
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
else
  VERSION="${1:?usage: scripts/release.sh <version> [--skip-notarize]}"
  [ "${2:-}" = "--skip-notarize" ] && SKIP_NOTARIZE=true
  APP="$PRODUCTS/Release/Ventilador.app"
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must look like 1.2.3 (got '$VERSION')" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"

if ! $PACKAGE_ONLY; then
  SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
  # A distributable build needs Apple's secure timestamp; a dry run doesn't, and works offline.
  $SKIP_NOTARIZE && TIMESTAMP="--timestamp=none" || TIMESTAMP="--timestamp"
  BUILD=1   # bump CURRENT_PROJECT_VERSION here if you ever ship two builds of one version
  rm -rf "$PRODUCTS"
  xcodegen generate --quiet
  xcodebuild build \
    -project Ventilador.xcodeproj -scheme Ventilador -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath build/DerivedData SYMROOT="$PWD/$PRODUCTS" OBJROOT="$PWD/build/release-intermediates" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    OTHER_CODE_SIGN_FLAGS="$TIMESTAMP" MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    | grep -E "^\*\* BUILD|: error: " || true
  [ -d "$APP" ] || { echo "build failed: $APP missing" >&2; exit 1; }
fi

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
zip_app() { ditto -c -k --keepParent --norsrc --noextattr --noqtn "$APP" "$ZIP"; }

if $PACKAGE_ONLY; then
  if $SKIP_NOTARIZE; then
    echo "skipping notarization checks: this zip is NOT distributable (Gatekeeper will reject it)"
  else
    xcrun stapler validate "$APP"                              # a notarization ticket is attached
    spctl --assess --type execute --verbose=2 "$APP"           # Gatekeeper accepts it
  fi
  zip_app
else
  zip_app
  if $SKIP_NOTARIZE; then
    echo "skipping notarization: this zip is NOT distributable (Gatekeeper will reject it)"
  else
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
    rm "$ZIP"
    zip_app                                                    # re-zip so the notarization ticket ships inside
  fi
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
