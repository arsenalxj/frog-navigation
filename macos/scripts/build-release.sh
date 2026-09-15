#!/bin/bash
set -euo pipefail

macos_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$macos_dir/build"
signing_name='Frog Local Code Signing'
signing_hash="$(/usr/bin/security find-identity -v -p codesigning "$HOME/Library/Keychains/login.keychain-db" | python3 -c '
import re, sys
matches = re.findall(r"\b([0-9A-Fa-f]{40}) \"Frog Local Code Signing\"", sys.stdin.read())
if len(matches) != 1:
    sys.exit("需要唯一有效的 Frog Local Code Signing 证书；首次配置请运行 scripts/setup-local-signing.sh。")
print(matches[0].upper())
')"
mkdir -p "$build_dir"
log_file="$build_dir/build-release-$(date +%Y%m%d-%H%M%S).log"
"$macos_dir/scripts/generate-icon.sh"
echo "构建 Apple Silicon Release；固定签名：${signing_name}；日志：$log_file"
if ! /usr/bin/xcodebuild \
  -project "$macos_dir/Frog.xcodeproj" \
  -scheme Frog \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$build_dir/DerivedData" \
  -clonedSourcePackagesDirPath "$build_dir/SourcePackages" \
  ARCHS=arm64 CODE_SIGNING_ALLOWED=YES "CODE_SIGN_IDENTITY=$signing_hash" CODE_SIGN_STYLE=Manual \
  build >"$log_file" 2>&1; then
  tail -n 100 "$log_file" >&2
  exit 1
fi

source_app="$build_dir/DerivedData/Build/Products/Release/青蛙导航.app"
stage_dir="$(mktemp -d "$build_dir/.frog-stage.XXXXXX")"
trap 'rm -rf -- "$stage_dir"' EXIT
/usr/bin/ditto "$source_app" "$stage_dir/青蛙导航.app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$stage_dir/青蛙导航.app"
/usr/bin/codesign -d "--extract-certificates=$stage_dir/signing-" "$stage_dir/青蛙导航.app" 2>/dev/null
actual_hash="$(/usr/bin/openssl x509 -inform DER -in "$stage_dir/signing-0" -noout -fingerprint -sha1 | /usr/bin/sed 's/.*=//; s/://g')"
[[ "$actual_hash" == "$signing_hash" ]] || { echo '实际签名证书与配置身份不匹配。' >&2; exit 1; }
requirement="$(/usr/bin/codesign -d -r- "$stage_dir/青蛙导航.app" 2>&1)"
[[ "$requirement" != *'cdhash H'* && "$requirement" == *'identifier "cn.arsenalxj.Frog"'* ]] || {
  echo '签名身份未形成稳定的证书要求，未交付。' >&2; exit 1;
}
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
