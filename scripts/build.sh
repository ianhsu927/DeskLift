#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
output="${1:-build/DeskLift.app}"
signing_identity="${DESKLIFT_SIGNING_IDENTITY:--}"
signing_settings=("CODE_SIGN_IDENTITY=$signing_identity")
version_pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))?$'
if [[ -n "${DESKLIFT_VERSION:-}" ]]; then
  [[ "$DESKLIFT_VERSION" =~ "$version_pattern" ]] || { print -u2 'Invalid DESKLIFT_VERSION'; exit 2; }
  signing_settings+=("MARKETING_VERSION=$DESKLIFT_VERSION")
fi
if [[ -n "${DESKLIFT_BUILD_NUMBER:-}" ]]; then
  [[ "$DESKLIFT_BUILD_NUMBER" =~ '^[1-9][0-9]*$' ]] || { print -u2 'Invalid DESKLIFT_BUILD_NUMBER'; exit 2; }
  signing_settings+=("CURRENT_PROJECT_VERSION=$DESKLIFT_BUILD_NUMBER")
fi
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
