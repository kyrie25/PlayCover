#!/bin/bash
set -euo pipefail

team="${1:?Missing development team}"
identifier="${2:?Missing runtime bundle identifier}"
scratch="${3:?Missing temporary directory}"

# Xcode can write workspace metadata beside the project. Keep the signed host sealed.
source="$scratch/RuntimeProvisioning"
/usr/bin/ditto "$(dirname "$0")" "$source"
/usr/bin/xcodebuild -quiet -project "$source/Provision.xcodeproj" \
    -scheme Provision -configuration Release \
    -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64' \
    -derivedDataPath "$scratch/DerivedData" \
    DEVELOPMENT_TEAM="$team" PRODUCT_BUNDLE_IDENTIFIER="$identifier" \
    CONFIGURATION_BUILD_DIR="$scratch/Products" -allowProvisioningUpdates build
/bin/cp "$scratch/Products/Provision.app/Contents/embedded.provisionprofile" \
    "$scratch/embedded.provisionprofile"
