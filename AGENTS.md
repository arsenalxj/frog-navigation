# 青蛙导航

原生、离线优先的 macOS / Windows 书签启动台，两端共用本地 JSON 数据格式。

- 所有回复和说明文档使用中文，每次回复开头先说“安安爸爸你好”。
- `macos/`：SwiftUI / AppKit 应用、Swift Package 测试及 Xcode 工程；执行 `cd macos && swift test`，打包执行 `./scripts/build-release.sh`，需要完整 Xcode 26。
- `windows/`：C++20 / Win32 / Direct2D 应用；在 Windows MSVC x64 环境从根目录执行 `powershell -NoProfile -ExecutionPolicy Bypass -File windows/scripts/build.ps1`。
- `assets/`：两个平台共用的品牌原始素材，使用小写短横线名称；`frog-navigation.png` 是用户提供的唯一应用图标源图，完整等比缩放，更新源图后重建平台资源，替换素材时清理失效版本。
- `plans/`：按功能命名的 `PLAN_*.md` 方案，功能移除时同步清理。
- `designs/`：平台原型，每个原型自带 HTML、JSX 和元数据；仅在对应界面重做时替换。
- `.github/workflows/`：桌面端 CI，不包含网站部署；生成产物放各平台忽略的 `build/`、`dist/`，可重建缓存按需清理，回滚归档清理前先检查是否仍需保留。
- 对外产品名称统一为“青蛙导航”；内部工程、模块、标识与目录统一使用 `Frog` / `frog` / `FROG`。旧版数据通过显式转换副本衔接，正式数据不由开发验证自动改写。
- 历史签名包、旧源码快照及原始验收记录存放在项目同级 `frog-navigation-history/` 的时间戳子目录，按来源保存；这些是历史备份，确认不再需要回滚后才清理。
- 测试使用隔离目录，保留现有工作区改动；提交、推送、安装和发布按当次用户授权执行。
