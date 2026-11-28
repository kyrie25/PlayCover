#!/bin/bash
set -euo pipefail

source_dir="${1:?Missing runtime source directory}"
team="${2:?Missing development team}"
output_app="${3:?Missing output bundle path}"
scratch="${4:?Missing scratch directory}"

# Copy sources into scratch so the signed PlayCover host bundle stays untouched.
work="$scratch/Source"
/usr/bin/ditto "$source_dir" "$work"

/usr/bin/env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" USER="$USER" LOGNAME="$LOGNAME" TMPDIR="$TMPDIR" \
  /usr/bin/xcodebuild -quiet -project "$work/Catalyst/CatalystRuntime.xcodeproj" \
  -scheme BaseiOSAppRuntime-Catalyst -configuration Release \
  -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64' \
  -derivedDataPath "$scratch/DerivedData" \
  SYMROOT="$scratch/Products" OBJROOT="$scratch/Intermediates" \
  DEVELOPMENT_TEAM="$team" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build

built="$scratch/Products/Release-maccatalyst/Runtime-Catalyst.app"
/usr/bin/codesign --verify --deep --strict "$built"

parent="$(dirname "$output_app")"
mkdir -p "$parent"
staged="$parent/.Runtime-Catalyst.$(uuidgen).noindex"
trap 'rm -rf "$staged"' EXIT
/usr/bin/ditto "$built" "$staged"
rm -rf "$output_app"
mv "$staged" "$output_app"
trap - EXIT
/usr/bin/codesign --verify --deep --strict "$output_app"
