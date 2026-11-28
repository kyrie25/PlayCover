#!/bin/bash
set -euo pipefail

ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SRC="$ROOT/PlayCover/Utils/CryptidPatch/CryptidPatch.m"
DEST="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/CryptidPatch.dylib"
SDK=$(/usr/bin/xcrun --sdk macosx --show-sdk-path)

/usr/bin/xcrun clang -target arm64-apple-ios15.0-macabi \
  -isysroot "$SDK" \
  -isystem "$SDK/System/iOSSupport/usr/include" \
  -iframework "$SDK/System/iOSSupport/System/Library/Frameworks" \
  -dynamiclib -fobjc-arc -framework Foundation \
  -install_name "@executable_path/Frameworks/CryptidPatch.dylib" \
  "$SRC" -o "$DEST"

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"
/usr/bin/codesign --force --sign "$IDENTITY" "$DEST"
