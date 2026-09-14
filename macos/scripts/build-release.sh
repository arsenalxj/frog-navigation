#!/bin/bash
set -euo pipefail

macos_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$macos_dir/build"
mkdir -p "$build_dir"
log_file="$build_dir/build-release-$(date +%Y%m%d-%H%M%S).log"
"$macos_dir/scripts/generate-icon.sh"
echo "构建 Apple Silicon Release；日志：$log_file"
if ! /usr/bin/xcodebuild \
  -project "$macos_dir/Frog.xcodeproj" \
  -scheme Frog \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$build_dir/DerivedData" \
  -clonedSourcePackagesDirPath "$build_dir/SourcePackages" \
  ARCHS=arm64 CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  build >"$log_file" 2>&1; then
  tail -n 100 "$log_file" >&2
  exit 1
fi

source_app="$build_dir/DerivedData/Build/Products/Release/青蛙导航.app"
stage_dir="$(mktemp -d "$build_dir/.frog-stage.XXXXXX")"
trap 'rm -rf -- "$stage_dir"' EXIT
/usr/bin/ditto "$source_app" "$stage_dir/青蛙导航.app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$stage_dir/青蛙导航.app"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$stage_dir/青蛙导航.app/Contents/Info.plist")"
[[ "$bundle_id" == 'cn.arsenalxj.Frog' ]] || { echo "构建产物 Bundle ID 不匹配。" >&2; exit 1; }
architecture="$(/usr/bin/lipo -archs "$stage_dir/青蛙导航.app/Contents/MacOS/Frog")"
[[ "$architecture" == 'arm64' ]] || { echo "构建产物应仅包含 arm64，实际为 ${architecture}。" >&2; exit 1; }
if [[ -e "$build_dir/青蛙导航.app" ]]; then
  old_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$build_dir/青蛙导航.app/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$old_id" == "$bundle_id" ]] || { echo "build/青蛙导航.app 不是已知青蛙导航产物，未覆盖。" >&2; exit 1; }
  rm -rf -- "$build_dir/青蛙导航.app"
fi
mv -- "$stage_dir/青蛙导航.app" "$build_dir/青蛙导航.app"
echo "构建及签名校验通过：$build_dir/青蛙导航.app"
echo "安装命令：$macos_dir/scripts/install.sh"
