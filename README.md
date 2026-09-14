# 青蛙导航

离线优先的原生书签启动台，支持 macOS 和 Windows。书签、文件夹与排序存储在本地 JSON，两端可以通过备份或自选同步目录交换数据，无需账号或服务器。

- [macOS 使用与构建](macos/README.md)：macOS 14+，SwiftUI / AppKit，Apple Silicon Release。
- [Windows 使用与构建](windows/README.md)：Windows 11 x64，C++20 / Win32 / Direct2D。

## 构建

macOS 需要完整 Xcode 26，在项目根目录执行：

```bash
cd macos
swift test
./scripts/build-release.sh
```

产物为 `macos/build/青蛙导航.app`。需要安装时执行 `macos/scripts/install.sh`；安装会核验 Frog 身份，同名不同身份的已安装应用须先另行备份；同身份更新保留回滚包。

Windows 需要 Visual Studio 的 C++ 桌面开发工具与 Windows SDK，在项目根目录执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows/scripts/build.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File windows/scripts/verify-package.ps1
```

产物为 `windows/dist/Frog-windows-x64.zip`，其中包含 `Frog.exe` 与安装／卸载脚本。两端构建与测试均通过上述本地命令执行。

## 目录

- `macos/`、`windows/`：平台源码、资源、测试与构建工具。
- `plans/`：桌面端功能方案；`designs/`：对应设计原型。

应用菜单、窗口及安装入口使用“青蛙导航”。内部工程、模块和标识统一使用 Frog，新版使用独立数据目录及 frog-bookmarks 格式。导入备份时须符合当前 `frog-bookmarks` 格式。原网页及浏览器扩展继续在原仓库维护。
