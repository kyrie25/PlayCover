#!/bin/bash
set -euo pipefail

: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple development team ID}"
ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
RUNTIME="$ROOT/Dependencies/iOSAppRunner"
CACHE="${DERIVED_FILE_DIR:-$ROOT/build.noindex}/IsolatedRuntime.noindex"
mkdir -p "$CACHE"

# Build a generated overlay so the pinned upstream submodule stays untouched.
SOURCE="$CACHE/Source"
mkdir -p "$SOURCE"
/usr/bin/rsync -a --delete --exclude=.git "$RUNTIME/" "$SOURCE/"
/bin/cp "$ROOT/PlayCover/IsolatedRuntime/PlayCoverRuntime.h" "$SOURCE/Runtime/PlayCoverRuntime.h"
/usr/bin/python3 - "$SOURCE/Runtime/main.m" <<'PYOVERLAY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text()
anchor = '    overwriteMainCFBundle();'
if text.count(anchor) != 1:
    raise SystemExit('Upstream runtime entry point changed; review the PlayCover overlay.')
text = '#import "PlayCoverRuntime.h"\n' + text.replace(anchor, anchor + '\n    PlayCoverRuntimeInit(appBundle);')
if text.count('@"apps/%@"') != 1:
    raise SystemExit('Upstream guest storage changed; review Spotlight exclusions.')
text = text.replace('@"apps/%@"', '@"apps.noindex/%@"')
path.write_text(text)
PYOVERLAY

# Catalyst cannot provision these iOS-only capabilities. Keep the upstream
# checkout untouched and use a build-specific entitlement file.
/usr/bin/python3 - "$RUNTIME/Runtime/Runtime.entitlements" "$CACHE/Runtime.entitlements" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as f:
    entitlements = plistlib.load(f)
for key in ('com.apple.developer.homekit', 'com.apple.developer.kernel.increased-memory-limit', 'inter-app-audio'):
    entitlements.pop(key, None)
# PlayTools reads the existing settings/keymaps and loads its user framework.
# Game data remains inside the runtime's sandbox.
entitlements['com.apple.security.temporary-exception.files.home-relative-path.read-write'] = [
    '/Library/Containers/io.playcover.PlayCover/'
]
entitlements['com.apple.security.temporary-exception.files.home-relative-path.read-only'] = [
    '/Library/Frameworks/PlayTools.framework/'
]
with open(sys.argv[2], 'wb') as f:
    plistlib.dump(entitlements, f)
PY

# Nested Xcode builds must not inherit PlayCover's package/resource build settings.
/usr/bin/env -i PATH="$PATH" HOME="$HOME" USER="$USER" LOGNAME="$LOGNAME" TMPDIR="$TMPDIR" \
    /usr/bin/xcodebuild -quiet -project "$SOURCE/iOSAppRunner.xcodeproj" \
    -scheme BaseiOSAppRuntime-Catalyst -configuration Release \
    -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64' \
    -derivedDataPath "$CACHE/DerivedData" \
    SYMROOT="$CACHE/Products" OBJROOT="$CACHE/Intermediates" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGN_ENTITLEMENTS="$CACHE/Runtime.entitlements" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration build

DEST="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/Runtime-Catalyst.app"
rm -rf "$DEST"
/usr/bin/ditto "$CACHE/Products/Release-maccatalyst/Runtime-Catalyst.app" "$DEST"
/usr/bin/codesign --verify --deep --strict "$DEST"

LAUNCHER="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/GameLauncher"
/usr/bin/xcrun clang -arch arm64 -fobjc-arc -framework AppKit \
    -mmacosx-version-min="${MACOSX_DEPLOYMENT_TARGET:-12.0}" \
    "$ROOT/PlayCover/IsolatedRuntime/GameLauncher.m" -o "$LAUNCHER"
/usr/bin/codesign --force --sign - "$LAUNCHER"

# Package the small Xcode target with the exact entitlements used for this runtime.
PROVISIONING="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/RuntimeProvisioning"
mkdir -p "$PROVISIONING/Provision.xcodeproj"
/bin/cp "$ROOT/Scripts/RuntimeProvisioning/Provision.xcodeproj/project.pbxproj" "$PROVISIONING/Provision.xcodeproj/"
/bin/cp "$ROOT/Scripts/RuntimeProvisioning/"{renew.sh,main.c} "$CACHE/Runtime.entitlements" "$PROVISIONING/"
