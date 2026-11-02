#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# Sign with the team configured in the Xcode project. The first build requires
# the developer's Apple Account in Xcode Settings > Accounts.
xcodebuild -project MacLooper.xcodeproj -scheme MacLooper-iPad \
    -destination 'generic/platform=iOS' -derivedDataPath build/iPadDevice \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
printf '\nBuilt: %s\n' "$PWD/build/iPadDevice/Build/Products/Debug-iphoneos/Mac Jams.app"
