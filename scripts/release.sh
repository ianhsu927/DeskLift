#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

fail() { print -u2 -- "$*"; exit 1; }
[[ $# == 1 ]] || fail 'Usage: ./scripts/release.sh vMAJOR.MINOR.PATCH'
tag="$1"
tag_pattern='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
[[ "$tag" =~ "$tag_pattern" ]] || fail 'Release tag must be vMAJOR.MINOR.PATCH, without leading zeros.'
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || fail 'Release packaging requires the Apple Silicon development Mac.'
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || fail 'Commit or stash working-tree changes before packaging a release.'
commit=$(git rev-parse HEAD)
tag_commit=$(git rev-parse --verify "refs/tags/$tag^{commit}") || fail 'Create the version tag before packaging.'
[[ "$tag_commit" == "$commit" ]] || fail 'The release tag must point to the checked-out commit.'

release_dir="$PWD/deliverables/$tag"
[[ ! -e "$release_dir" ]] || fail "Release output already exists: $release_dir (preserved; choose a fresh checkout)."
mkdir -p "$PWD/deliverables"
stage_dir=$(mktemp -d "$PWD/deliverables/.${tag}.XXXXXX")
verify_dir=''
cleanup() {
  if [[ -n "$verify_dir" ]]; then rm -rf "$verify_dir"; fi
  if [[ -d "$stage_dir" ]]; then print -u2 -- "Partial release output preserved: $stage_dir"; fi
}
trap cleanup EXIT
timestamp=$(TZ=Asia/Shanghai date +%Y%m%d-%H%M%S)
version="${tag#v}"
build_number="${GITHUB_RUN_NUMBER:-10}"
[[ "$build_number" =~ '^[1-9][0-9]*$' ]] || fail 'Build number must be a positive integer.'
package_name="DeskLift-$tag"
package_dir="$stage_dir/$package_name"
mkdir -p "$package_dir"

# These entry points run offline tests and compile the app. Never launch the app
# or call a real Bluetooth/desk command as part of a release.
./scripts/test.sh
DESKLIFT_SIGNING_IDENTITY=- DESKLIFT_DEVELOPMENT_TEAM='' \
  DESKLIFT_VERSION="$version" DESKLIFT_BUILD_NUMBER="$build_number" \
  ./scripts/build.sh "$package_dir/DeskLift.app"

app="$package_dir/DeskLift.app"
plist="$app/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" == local.ian.desklift ]] || fail 'Unexpected app bundle identifier.'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" == "$version" ]] || fail 'Built app version does not match the release tag.'
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" == "$build_number" ]] || fail 'Built app build number does not match this run.'
[[ "$(lipo -archs "$app/Contents/MacOS/DeskLift")" == arm64 ]] || fail 'Unexpected executable architecture.'
[[ -f "$app/Contents/Resources/THIRD-PARTY-NOTICES.txt" ]] || fail 'Third-party notices are missing from the app.'
codesign --verify --deep --strict "$app"
cp README.md THIRD-PARTY-NOTICES.txt "$package_dir/"
if [[ -f LICENSE ]]; then cp LICENSE "$package_dir/"; fi

zip_name="DeskLift-$tag-macos-arm64.zip"
source_name="DeskLift-$tag-source.tar.gz"
ditto -c -k --sequesterRsrc --keepParent "$package_dir" "$stage_dir/$zip_name"
verify_dir=$(mktemp -d "${TMPDIR:-/tmp/}desklift-release-verify.XXXXXX")
ditto -x -k "$stage_dir/$zip_name" "$verify_dir"
codesign --verify --deep --strict "$verify_dir/$package_name/DeskLift.app"
git archive --format=tar.gz --prefix="DeskLift-$tag-source/" "$commit" > "$stage_dir/$source_name"
(
  cd "$stage_dir"
  shasum -a 256 "$zip_name" "$source_name" > SHA256SUMS.txt
  shasum -a 256 -c SHA256SUMS.txt
)

notes="$stage_dir/release-notes-$timestamp.md"
cat > "$notes" <<EOF
DeskLift $tag，适用于 Apple Silicon Mac（arm64），最低 macOS 14。

- 应用版本：$version；构建号：$build_number。
- 源码提交：$commit。
- 验证：完整离线测试、Release 构建、应用版本与架构检查、代码签名完整性检查。
- 下载 \`$zip_name\`，解压后将 DeskLift.app 拖入「应用程序」。
- \`$source_name\` 包含本版本源码、脚本、测试和第三方声明；\`SHA256SUMS.txt\` 用于校验下载文件。

此自动发布流程使用临时签名，未进行 Apple 公证。Siri / 快捷指令的开发签名要求见包内 README。
构建和测试不会连接蓝牙设备或驱动升降桌。
EOF

# Actions may clean its checkout on the next run. Retain the exact source and
# distributable files on this Mac outside that workspace; never copy caches.
archive_root="${DESKLIFT_RELEASE_ARCHIVE_DIR:-$HOME/Library/Application Support/DeskLift/releases}"
archive_dir="$archive_root/$tag/$timestamp-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
[[ ! -e "$archive_dir" ]] || fail "Release archive already exists: $archive_dir"
mkdir -p "$archive_dir"
cp "$stage_dir/$zip_name" "$stage_dir/$source_name" "$stage_dir/SHA256SUMS.txt" "$notes" "$archive_dir/"
mv "$stage_dir" "$release_dir"
print -- "Packaged $release_dir"
print -- "Recovery copy: $archive_dir"
