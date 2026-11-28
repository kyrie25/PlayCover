#!/bin/bash
set -euo pipefail

ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
RUNTIME="$ROOT/PlayCover/IsolatedRuntime/Catalyst"
RESOURCES="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}"
DEST="$RESOURCES/Runtime-Catalyst.app"
SOURCE_BUNDLE="$RESOURCES/IsolatedRuntimeSource"

if [ "${PLAYCOVER_DEFER_RUNTIME_BUILD:-0}" = "1" ] || [ -z "${DEVELOPMENT_TEAM:-}" ]; then
  # CI / self-signed builds defer Catalyst signing to the user's local Xcode on first isolated launch.
  rm -rf "$DEST" "$SOURCE_BUNDLE"
  mkdir -p "$SOURCE_BUNDLE/Catalyst"
  /bin/cp "$ROOT/PlayCover/IsolatedRuntime/PlayCoverRuntime.h" "$SOURCE_BUNDLE/"
  /bin/cp "$ROOT/Scripts/RuntimeProvisioning/build-local.sh" "$SOURCE_BUNDLE/"
  /usr/bin/ditto "$RUNTIME/CatalystRuntime.xcodeproj" "$SOURCE_BUNDLE/Catalyst/CatalystRuntime.xcodeproj"
  /usr/bin/ditto "$RUNTIME/Runtime" "$SOURCE_BUNDLE/Catalyst/Runtime"
  /usr/bin/ditto "$RUNTIME/litehook" "$SOURCE_BUNDLE/Catalyst/litehook"
  /bin/cp "$RUNTIME/LICENSE" "$RUNTIME/SOURCES.md" "$SOURCE_BUNDLE/Catalyst/"
else
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

  rm -rf "$DEST" "$SOURCE_BUNDLE"
  /usr/bin/ditto "$CACHE/Products/Release-maccatalyst/Runtime-Catalyst.app" "$DEST"
  /usr/bin/codesign --verify --deep --strict "$DEST"
fi

LAUNCHER="$RESOURCES/GameLauncher"
/usr/bin/xcrun clang -arch arm64 -fobjc-arc -framework AppKit \
  -mmacosx-version-min="${MACOSX_DEPLOYMENT_TARGET:-12.0}" \
  "$ROOT/PlayCover/IsolatedRuntime/GameLauncher.m" -o "$LAUNCHER"
/usr/bin/codesign --force --sign - "$LAUNCHER"

# Package the small Xcode target with the exact entitlements used for this runtime.
PROVISIONING="$RESOURCES/RuntimeProvisioning"
mkdir -p "$PROVISIONING/Provision.xcodeproj"
/bin/cp "$ROOT/Scripts/RuntimeProvisioning/Provision.xcodeproj/project.pbxproj" "$PROVISIONING/Provision.xcodeproj/"
/bin/cp "$ROOT/Scripts/RuntimeProvisioning/"{renew.sh,main.c} "$RUNTIME/Runtime/Runtime.entitlements" "$PROVISIONING/"
