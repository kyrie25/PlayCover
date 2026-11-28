#!/bin/bash
set -euo pipefail

# Nightly/release identity import. No login-keychain or system trust changes.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?Usage: bash Scripts/sign-macos.sh app-path}"
cd "$ROOT"

: "${PLAYCOVER_CODESIGN_P12:?Persistent signing certificate is required}"
: "${PLAYCOVER_CODESIGN_PASSWORD:?Signing certificate password is required}"

IDENTIFIER="${PLAYCOVER_BUNDLE_IDENTIFIER:-io.playcover.PlayCover}"
ACTUAL=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")
test "$ACTUAL" = "$IDENTIFIER"

FINGERPRINT=$(/usr/bin/openssl x509 -in "$ROOT/Scripts/codesign.pem" -noout -fingerprint -sha1 | /usr/bin/sed 's/.*=//;s/://g')
REQUIREMENT="identifier \"$IDENTIFIER\" and certificate leaf = H\"$FINGERPRINT\""

umask 077
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/playcover-codesign.XXXXXX")
KEYCHAIN="$STAGE/signing.keychain-db"
cleanup() {
  /usr/bin/security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  rm -rf "$STAGE"
}
trap cleanup EXIT

SEARCH_LIST=()
while IFS= read -r entry; do
  entry="${entry#*\"}"
  SEARCH_LIST+=("${entry%\"*}")
done < <(/usr/bin/security list-keychains -d user)

printf '%s' "$PLAYCOVER_CODESIGN_P12" | /usr/bin/base64 --decode > "$STAGE/identity.p12"
KEYCHAIN_PASSWORD=$(/usr/bin/openssl rand -hex 32)
printf '%s\n' 'Signing phase: import isolated identity'
/usr/bin/security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
/usr/bin/security set-keychain-settings -lut 3600 "$KEYCHAIN"
/usr/bin/security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
/usr/bin/security import "$STAGE/identity.p12" -k "$KEYCHAIN" -P "$PLAYCOVER_CODESIGN_PASSWORD" -T /usr/bin/codesign >/dev/null
/usr/bin/security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
# Deleting our temporary Keychain removes only this entry during cleanup.
/usr/bin/security list-keychains -d user -s "$KEYCHAIN" "${SEARCH_LIST[@]}"

printf '%s\n' 'Signing phase: select pinned identity and sign'
/usr/bin/security find-identity -p codesigning "$KEYCHAIN"

sign_nested() {
  local target="$1"
  shift
  if [ -e "$target" ]; then
    /usr/bin/codesign --force --sign "$FINGERPRINT" --keychain "$KEYCHAIN" --timestamp=none "$@" "$target"
  fi
}

PLAYTOOLS="$APP/Contents/Frameworks/PlayTools.framework"
sign_nested "$PLAYTOOLS/PlugIns/AKInterface.bundle" --deep
sign_nested "$PLAYTOOLS" --deep

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
sign_nested "$SPARKLE/Versions/B/Autoupdate" -o runtime
sign_nested "$SPARKLE/Versions/B/Updater.app" -o runtime
sign_nested "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" -o runtime
sign_nested "$SPARKLE/Versions/B/XPCServices/Installer.xpc" -o runtime
sign_nested "$SPARKLE" -o runtime

sign_nested "$APP/Contents/Resources/GameLauncher" -o runtime

/usr/bin/codesign --force --options runtime --sign "$FINGERPRINT" --keychain "$KEYCHAIN" --timestamp=none \
  --requirements "=designated => $REQUIREMENT" "$APP"
/usr/bin/codesign --verify --deep --strict -R "=$REQUIREMENT" "$APP"
/usr/bin/codesign -d -r- "$APP"
