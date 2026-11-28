#!/bin/bash
set -euo pipefail

: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple development team ID}"
ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
RUNTIME="$ROOT/PlayCover/IsolatedRuntime/Catalyst"
CACHE="${DERIVED_FILE_DIR:-$ROOT/build.noindex}/IsolatedRuntime.noindex"
mkdir -p "$CACHE"

# Nested Xcode builds must not inherit PlayCover's package/resource build settings.
/usr/bin/env -i PATH="$PATH" HOME="$HOME" USER="$USER" LOGNAME="$LOGNAME" TMPDIR="$TMPDIR" \
    /usr/bin/xcodebuild -quiet -project "$RUNTIME/CatalystRuntime.xcodeproj" \
    -scheme BaseiOSAppRuntime-Catalyst -configuration Release \
    -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64' \
    -derivedDataPath "$CACHE/DerivedData" \
    SYMROOT="$CACHE/Products" OBJROOT="$CACHE/Intermediates" \
    DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
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
/bin/cp "$ROOT/Scripts/RuntimeProvisioning/"{renew.sh,main.c} "$RUNTIME/Runtime/Runtime.entitlements" "$PROVISIONING/"
