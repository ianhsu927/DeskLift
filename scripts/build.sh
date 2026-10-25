#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
output="${1:-build/DeskLift.app}"
signing_identity="${DESKLIFT_SIGNING_IDENTITY:--}"
signing_settings=("CODE_SIGN_IDENTITY=$signing_identity")
if [[ -n "${DESKLIFT_DEVELOPMENT_TEAM:-}" ]]; then
  signing_settings+=("DEVELOPMENT_TEAM=$DESKLIFT_DEVELOPMENT_TEAM")
fi
xcodebuild -quiet -project DeskLift.xcodeproj -scheme DeskLift \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData "${signing_settings[@]}" build
stage=$(mktemp -d "${TMPDIR:-/tmp/}desklift.XXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/DeskLift.app"
ditto --norsrc --noextattr --noqtn build/DerivedData/Build/Products/Release/DeskLift.app "$app"
xattr -cr "$app"
codesign --force --sign "$signing_identity" "$app"
codesign --verify --deep --strict "$app"
mkdir -p "${output:h}"
ditto --norsrc --noextattr --noqtn "$app" "$output"
xattr -cr "$output"
codesign --verify --deep --strict "$output"
echo "Built $output"
