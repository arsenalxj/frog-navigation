# 青蛙导航

离线优先的原生书签启动台，支持 macOS 和 Windows。书签、文件夹与排序存储在本地 JSON（`frog-bookmarks` 格式，版本 1），两端可以互相恢复备份，也可以通过自选目录交给坚果云等同步工具共享数据，无需账号或服务器。

## 功能

- **终端界面**：macOS 与 Windows 均为原生树形单列表、命令行与缓冲区，1440 × 900 设计坐标等比缩放；不使用壁纸背景或网页运行时。
- **书签管理**：添加、双字段编辑、确认删除、文件夹原地展开、同组排序、移动和拖动成组；两端均使用本地首字符与稳定传统色图标，不下载网站图标。
- **计算器**：四则运算、括号、小数与指数，历史选择和复制结果；关闭后保留本次运行的算式与历史。
- **搜索**：覆盖全部书签（含文件夹内），方向键选择、回车打开；没有结果时回车直接打开输入的网址或使用 Google 搜索。
- **全局快捷键**：后台驻留时随时展开／收起启动台，可自定义组合（macOS 默认 `⌥Space`，Windows 默认 `Ctrl+Alt+Space`）。
- **屏幕触角**：鼠标推到屏幕角落即展开，默认左下角，可选四角或关闭。
- **Finder 目录快跳（仅 macOS）**：在系统打开／保存窗口中进入 Finder 当前目录，默认关闭，需按引导授权；Windows 不实现此功能。
- **键盘操作**：方向键选择、回车打开、`/` 聚焦搜索、Esc 逐层关闭等完整键盘流程。
- **登录时启动**：静默驻留后台，通过重新启动应用、Windows 托盘、快捷键或触角唤起。

## 使用

### macOS

需要 macOS 14 及以上，交付 Apple Silicon `arm64` 版本，安装到 `/Applications/青蛙导航.app`：

```bash
cd macos
./scripts/setup-local-signing.sh   # 首次配置本机签名
./scripts/build-release.sh
./scripts/install.sh
open /Applications/青蛙导航.app
```

详细使用说明（按键表、数据目录、备份恢复、屏幕触角、Finder 目录快跳等）见 [macos/README.md](macos/README.md)。

### Windows

需要 Windows 11 x64。解压 `Frog-windows-x64.zip`，进入 `Frog/` 目录双击 `Frog.exe` 即可运行；也可执行包内 `install.ps1` 安装到当前用户目录，`uninstall.ps1` 卸载。无需管理员权限。

详细使用说明（快捷键、托盘、数据与恢复、构建与验证）见 [windows/README.md](windows/README.md)。

### 数据与同步

- 默认数据目录：macOS 为 `~/Library/Application Support/Frog/bookmarks.json`，Windows 为 `%LOCALAPPDATA%\Frog\Data\bookmarks.json`。
- `:cd <目录>` 切换数据目录，`:backup [路径]` 另存完整 JSON 副本，`:restore [路径]` 校验后整体替换当前数据。
- 把数据目录选在坚果云等同步工具管理的文件夹即可跨设备共享；应用不直接做网络同步，切换设备前请等待同步完成。
- 两端数据格式互通：macOS 导出的备份可直接在 Windows 恢复，反之亦然。
- 两端可用 `:import edge` 从本机 Microsoft Edge 只读导入收藏夹，嵌套文件夹压平为路径组名，全局按网址精确去重。

## 构建

macOS 需要完整 Xcode 26，在 `macos/` 目录执行：

```bash
swift test
./scripts/build-release.sh
```

Windows 需要 Visual Studio 的 C++ 桌面开发工具与 Windows SDK，在项目根目录执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows/scripts/build.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File windows/scripts/verify-package.ps1
```

产物分别为 `macos/build/青蛙导航.app` 与 `windows/dist/Frog-windows-x64.zip`。各平台构建、签名与验收细节见对应目录的 README。

## 目录

- `macos/`、`windows/`：平台源码、资源、测试与构建工具。
- `assets/`：两端共用的品牌素材；`designs/`：界面设计原型；`plans/`：功能方案。

应用菜单、窗口及安装入口使用“青蛙导航”。内部工程、模块和标识统一使用 Frog。导入备份时须符合当前 `frog-bookmarks` 格式。原网页及浏览器扩展继续在原仓库维护。
