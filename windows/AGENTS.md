# Windows 客户端

用途：把 青蛙导航 书签启动台原生移植到 Windows 11 x64，数据与 macOS 客户端互通。

- 技术：C++20、Win32、Direct2D / DirectWrite、WIC；使用 MSVC 和 CMake，不使用前端运行时。
- `src/` 放实现，按 `core/`（模型和存储）、`platform/`（Windows 集成）、`ui/`（窗口和绘制）分层；文件使用 PascalCase。
- `resources/` 放 manifest 与应用资源；`tests/` 放 CTest 测试及兼容数据；`scripts/` 放小写连字符命名的 PowerShell 构建、安装及验证脚本。
- Windows 交付文件和目录名仅使用 ASCII：`Frog.exe`、`Frog-windows-x64.zip`、ZIP 根目录 `Frog/`；界面显示名称为“青蛙导航”。
- `build/` 放依赖下载、构建、测试临时目录和验收证据；`dist/` 放 Release ZIP。二者均忽略，可在对应进程退出后整体清理，不承载用户数据。
- 应用图标源为 `../assets/frog-navigation.png`；`scripts/generate-icon.ps1` 等比生成 `resources/AppIcon.ico` 的 16–256 像素各档资源，构建时自动执行；关于页复用应用图标。
- 构建和检查：`powershell -ExecutionPolicy Bypass -File windows/scripts/build.ps1`，默认构建 x64 Release、执行 CTest 并打包。
- 正式数据使用 `%LOCALAPPDATA%\Frog\Data`，隔离检查必须使用 `--data-directory`；不得在自动测试中修改真实数据、快捷键偏好或登录启动注册。
- 数据契约以 `macos/Sources/FrogCore/BookmarkDocument.swift` 为准；根书签的 `groupId` 必须显式为 `null`，ID 必须是 UUID。
- 实施方案：[PLAN_WINDOWS.md](../plans/PLAN_WINDOWS.md)；使用与维护说明：[README.md](README.md)；实际验收记录：[VALIDATION.md](VALIDATION.md)。
