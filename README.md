# 青蛙导航

原生、离线优先的 macOS / Windows 书签启动台。用键盘搜索和打开书签，用文件夹整理常用网站；数据保存在本地 JSON，无需账号或服务器。

两端共用 `frog-bookmarks` 版本 1 数据格式，备份可互相恢复，也可将数据目录交给坚果云等工具同步。

[macOS 使用说明](macos/README.md) · [Windows 使用说明](windows/README.md) · [数据与同步](#数据与同步) · [从源码构建](#从源码构建)

## 平台支持

| 平台 | 系统要求 | 应用形态 | 默认唤起快捷键 |
| --- | --- | --- | --- |
| macOS | macOS 14 及以上，Apple Silicon（arm64） | AppKit 原生应用 | `⌥Space` |
| Windows | Windows 11 x64 | Win32 / Direct2D 原生应用 | `Ctrl+Alt+Space` |

两端采用“回声终端”界面：树形单列表、底部命令行、日志与缓冲区，不嵌入网页运行时。快捷键可自定义；应用驻留后台时，也可通过屏幕触角唤起，默认使用左下角。

## 主要功能

- **书签管理**：添加、编辑、确认删除、同组排序、移动和拖动成组；文件夹原地展开／折叠。书签图标使用本地首字符与稳定传统色，不下载网站图标。
- **全局搜索**：覆盖所有文件夹内的书签，方向键选择、回车打开；无结果时，回车直接打开输入的网址或使用 Google 搜索。收起窗口后清空搜索，再次唤起恢复未筛选列表。
- **键盘与命令操作**：`/` 聚焦搜索，方向键选择，回车打开，Esc 逐层关闭；通过底部 `:` 命令管理书签、设置和数据。
- **计算器**：支持四则运算、括号、小数与指数，可选择历史和复制结果；关闭计算器后保留本次运行的算式与历史。
- **导入与备份**：只读导入本机 Microsoft Edge 收藏夹，导出完整 JSON 备份，并在两端恢复。
- **后台驻留**：支持登录时静默启动，通过快捷键、屏幕触角或重新启动应用唤起；Windows 另有托盘入口。
- **Finder 目录快跳（仅 macOS）**：在系统打开／保存窗口中进入 Finder 当前目录。默认关闭，需按引导授权；Windows 不提供此功能。

## 开始使用

### Windows

1. 解压 `Frog-windows-x64.zip`。
2. 进入 `Frog/` 目录，双击 `Frog.exe`。
3. 如需安装，执行包内 `install.ps1`，默认安装到 `%LOCALAPPDATA%\Programs\Frog`，无需管理员权限或独立 VC++ 运行库。

更新前先从托盘退出旧进程。包内 `uninstall.ps1` 用于卸载，卸载保留用户书签与偏好。

快捷键、命令表、托盘和安装细节见 [Windows 使用说明](windows/README.md)。

### macOS

当前通过本机构建并安装到 `/Applications/青蛙导航.app`，步骤见下方[从源码构建](#从源码构建)。更新前先用 `Command-Q` 退出已有应用。

使用固定本机自签名证书，无需付费 Apple 开发者账号；该签名不等同于 Apple Developer ID 签名或公证。

按键表、屏幕触角、登录启动和 Finder 目录快跳授权见 [macOS 使用说明](macos/README.md)。

## 数据与同步

### 本地存储

| 平台 | 默认书签文件 |
| --- | --- |
| macOS | `~/Library/Application Support/Frog/bookmarks.json` |
| Windows | `%LOCALAPPDATA%\Frog\Data\bookmarks.json` |

书签、文件夹与排序保存在 JSON 中。导入备份须符合当前 `frog-bookmarks` 格式；macOS 导出的备份可在 Windows 恢复，反之亦然。

### 常用数据命令

在应用底部命令行输入：

| 命令 | 用途 |
| --- | --- |
| `:cd <目录>` | 切换数据目录 |
| `:backup [路径]` | 另存完整 JSON 备份 |
| `:restore [路径]` | 校验备份后整体替换当前数据，**不是合并** |
| `:import edge` | 只读导入本机 Microsoft Edge 收藏夹 |

Edge 导入会将嵌套文件夹压平为路径组名，并按网址精确去重。恢复备份前，建议先备份当前数据。

### 跨设备同步

将数据目录设为坚果云等同步工具管理的文件夹即可共享数据。应用本身不提供网络同步服务；切换设备前请等待同步完成，避免多端同时编辑。

## 从源码构建

以下命令均从仓库根目录开始执行。平台 README 提供完整构建、签名与验收说明。

### macOS

需要包含 Icon Composer / `ictool` 的完整 **Xcode 26**，并完成首次启动配置。

```bash
cd macos
swift test
./scripts/setup-local-signing.sh   # 首次配置本机签名
./scripts/build-release.sh
./scripts/install.sh
open /Applications/青蛙导航.app
```

构建产物：`macos/build/青蛙导航.app`。构建脚本不自动运行测试、安装或启动应用，上述步骤分别执行。

### Windows

需要 **Visual Studio 2022 / 2026** 的 C++ 桌面开发工作负载、**Windows 11 SDK** 和 **CMake**。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows/scripts/build.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File windows/scripts/verify-package.ps1
```

构建产物：`windows/dist/Frog-windows-x64.zip`。默认构建 x64 Release、执行测试并打包；首次构建需下载固定校验值的 nlohmann/json，后续可离线编译。原生桌面验收需要解锁的交互桌面，期间不要操作测试窗口。

## 项目结构与文档

| 路径 | 内容 |
| --- | --- |
| [`macos/`](macos/) | macOS 源码、资源、测试、Xcode 工程与构建脚本 |
| [`windows/`](windows/) | Windows 源码、资源、测试与构建脚本 |
| [`assets/`](assets/) | 两端共用的品牌素材，`frog-navigation.png` 为应用图标源图 |
| [`designs/`](designs/) | 界面设计原型 |
| [`plans/`](plans/) | 功能方案 |

已验证项目及未验证边界见 [macOS 验收记录](macos/VALIDATION.md) 与 [Windows 验收记录](windows/VALIDATION.md)。

对外产品名称统一为“青蛙导航”，内部工程、模块与标识使用 `Frog` / `frog` / `FROG`。本仓库维护原生桌面应用，原网页及浏览器扩展继续在原仓库维护。
