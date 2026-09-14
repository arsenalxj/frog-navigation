#!/bin/bash
set -euo pipefail

macos_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source_app="$macos_dir/build/青蛙导航.app"
destination_dir="${1:-/Applications}"
expected_id='cn.arsenalxj.Frog'
if [[ $# -gt 1 || "$destination_dir" != /* ]]; then
  echo '用法：scripts/install.sh [应用程序目录的绝对路径]；默认为 /Applications。' >&2
  exit 1
fi
[[ -d "$source_app" ]] || { echo '请先运行 scripts/build-release.sh。' >&2; exit 1; }
[[ -d "$destination_dir" && -w "$destination_dir" ]] || { echo "目标目录不存在或不可写：$destination_dir" >&2; exit 1; }
destination_dir="$(cd -- "$destination_dir" && pwd -P)"
destination="$destination_dir/青蛙导航.app"
previous_destination="$destination"
legacy_destination="$destination_dir/Frog.app"
if [[ -e "$legacy_destination" || -L "$legacy_destination" ]]; then
  [[ ! -e "$destination" && ! -L "$destination" ]] || { echo '旧 Frog.app 与青蛙导航.app 同时存在，请先明确保留的版本。' >&2; exit 1; }
  previous_destination="$legacy_destination"
fi
[[ ! -L "$previous_destination" ]] || { echo "目标是符号链接，未覆盖：$destination" >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$source_app"
source_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$source_app/Contents/Info.plist")"
[[ "$source_id" == "$expected_id" ]] || { echo '源应用标识不匹配。' >&2; exit 1; }
while IFS= read -r running_pid; do
  [[ -n "$running_pid" ]] || continue
  running_executable="$(/bin/ps -ww -p "$running_pid" -o comm= 2>/dev/null || true)"
  if [[ "$running_executable" == /* && -d "$(dirname -- "$running_executable")" ]]; then
    running_executable="$(cd -- "$(dirname -- "$running_executable")" && pwd -P)/$(basename -- "$running_executable")"
  fi
  if [[ "$running_executable" == "$destination/Contents/MacOS/Frog" || "$running_executable" == "$previous_destination/Contents/MacOS/Frog" ]]; then
    echo '目标青蛙导航正在运行，请在应用中按 Command-Q 完全退出后再安装。' >&2
    exit 1
  fi
done < <(/usr/bin/pgrep -x Frog || true)
if [[ -e "$previous_destination" ]]; then
  installed_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$previous_destination/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$installed_id" == "$expected_id" ]] || { echo "同名应用标识未知，未覆盖：$destination" >&2; exit 1; }
  /usr/bin/codesign --verify --deep --strict "$previous_destination"
fi

lock_dir="$destination_dir/.frog-install.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
  echo "安装目录已被占用，请检查此前安装是否结束：$lock_dir" >&2
  exit 1
fi
stage_dir=''
previous_app=''
new_installed=false
committed=false
archive_path=''
cleanup() {
  local result=$?
  trap - EXIT INT TERM
  set +e
  if [[ "$committed" != true && -n "$previous_app" && -d "$previous_app" ]]; then
    if [[ -e "$destination" && "$new_installed" == true ]]; then
      mv -- "$destination" "$stage_dir/failed.app"
    fi
    if [[ ! -e "$previous_destination" && ! -L "$previous_destination" ]]; then
      mv -- "$previous_app" "$previous_destination"
      /usr/bin/codesign --verify --deep --strict "$previous_destination"
      if [[ $? -eq 0 ]]; then echo '安装未完成，旧版已恢复。' >&2; fi
    fi
    if [[ -d "$previous_app" ]]; then
      echo "无法自动恢复旧版，已保留原应用：$previous_app" >&2
      result=1
    fi
  elif [[ "$committed" != true && "$new_installed" == true && -e "$destination" ]]; then
    mv -- "$destination" "$stage_dir/failed.app"
  fi
  if [[ -n "$stage_dir" && ( "$committed" == true || ! -d "$previous_app" ) ]]; then
    if ! rm -rf -- "$stage_dir"; then
      echo "临时安装目录未能清理：$stage_dir" >&2
      result=1
    fi
  fi
  rmdir "$lock_dir" 2>/dev/null
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

stage_dir="$(mktemp -d "$destination_dir/.frog-install.XXXXXX")"
mkdir "$stage_dir/new" "$stage_dir/previous"
staged_app="$stage_dir/new/青蛙导航.app"
previous_app="$stage_dir/previous/$(basename -- "$previous_destination")"
/usr/bin/ditto "$source_app" "$staged_app"
/usr/bin/codesign --verify --deep --strict "$staged_app"
if [[ -e "$previous_destination" ]]; then
  mv -- "$previous_destination" "$previous_app"
fi
mv -- "$staged_app" "$destination"
new_installed=true
/usr/bin/codesign --verify --deep --strict "$destination"
cmp -s "$source_app/Contents/MacOS/Frog" "$destination/Contents/MacOS/Frog"
/usr/bin/touch "$destination"
if [[ -d "$previous_app" ]]; then
  archive_dir="$macos_dir/build/install-backup"
  mkdir -p "$archive_dir"
  archive_path="$archive_dir/Frog-previous.zip"
  python3 -B "$macos_dir/scripts/installer_archive.py" archive "$previous_app" "$archive_path" --replace > "$stage_dir/archive-result.json"
fi
committed=true
echo "已安装：$destination"
if [[ -n "$archive_path" ]]; then echo "旧版已验证并归档：$archive_path"; fi
if /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$destination"; then
  echo '已刷新该应用的系统注册和图标信息。'
else
  registration_status=$?
  echo "安装已完成，但图标注册刷新失败（退出码 ${registration_status}）：$destination" >&2
fi
echo '可在 Finder 打开青蛙导航，再右键 Dock 图标 → 选项 → 在程序坞中保留。'
