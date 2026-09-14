#!/bin/bash
set -euo pipefail

macos_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
developer_dir="$(/usr/bin/xcode-select -p)"
ictool="$developer_dir/../Applications/Icon Composer.app/Contents/Executables/ictool"
preview_dir="$macos_dir/build/icon-preview"
mkdir -p "$preview_dir" "$macos_dir/Resources"
if [[ ! -x "$ictool" ]]; then
  echo "缺少 Xcode 26 的 Icon Composer 命令行工具：$ictool" >&2
  exit 1
fi

stage_dir="$(mktemp -d "$macos_dir/build/.icon-generation.XXXXXX")"
trap 'rm -rf -- "$stage_dir"' EXIT
/usr/bin/xcrun swift "$macos_dir/scripts/render_app_icon.swift" "$macos_dir/../assets/frog-navigation.png" "$macos_dir/Resources" "$preview_dir" "$macos_dir/../windows/resources/AppIcon.ico"
for size in 128 1024; do
  "$ictool" "$macos_dir/Resources/AppIcon.icon" \
    --export-image --output-file "$preview_dir/macos-default-${size}.png" \
    --platform macOS --rendition Default --width "$size" --height "$size" --scale 1 >/dev/null
done

# 由 Apple 编译器同时处理 macOS 26 分层资产和旧系统兼容图标。
# Xcode 工程编译相同 .icon，包含 Assets.car 与 ICNS；不只复制传统 ICNS。
/usr/bin/xcrun actool "$macos_dir/Resources/AppIcon.icon" \
  --compile "$stage_dir" --platform macosx --minimum-deployment-target 14.0 \
  --app-icon AppIcon --output-partial-info-plist "$stage_dir/asset-info.plist" \
  --output-format human-readable-text --warnings --notices >"$preview_dir/compile.log" 2>&1
# actool 的图标导出失败可能只产生 warning 并返回 0，因此检查本次独立目录的产物。
for output in AppIcon.icns Assets.car asset-info.plist; do
  [[ -s "$stage_dir/$output" ]] || { cat "$preview_dir/compile.log" >&2; echo "缺少图标编译产物：$output" >&2; exit 1; }
done
icon_name="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIconName' "$stage_dir/asset-info.plist")"
[[ "$icon_name" == AppIcon ]] || { echo "编译的图标名称不匹配。" >&2; exit 1; }
cp "$stage_dir/AppIcon.icns" "$macos_dir/Resources/AppIcon.icns"
echo "已生成原生分层图标和兼容 ICNS；系统渲染预览：$preview_dir"
