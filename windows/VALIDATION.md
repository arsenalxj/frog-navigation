# Windows 当前验证

内部身份已统一为 Frog。旧身份的原始验收记录归档到项目同级 `frog-navigation-history/20260915-051305/`，不作为本次身份变更的验证结果。

2026-09-15 检查结果：

- CMake 源文件路径、资源和安装打包路径一致；PowerShell 文件保持 UTF-8 BOM。
- 当前 `frog-bookmarks` fixture 已通过 macOS FrogCore 解码与往返测试。
- Windows x64 Release 已在 MSVC 19.51 / Visual Studio 2026 环境构建成功。
- CTest 全部通过：`core`、`native-smoke`，共 2 项；原生运行测试使用隔离数据目录。
- ZIP 解包与 Release 可执行文件一致性、ASCII 文件名、隔离首次安装、更新、旧版中文可执行名升级、未知目录保护、卸载及隔离数据保留检查全部通过；报告位于 `build/verification/package-report.json`。
- 完整人工交互验收、性能测量及真实用户目录安装尚未执行。

在 Windows 项目根目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows/scripts/build.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File windows/scripts/verify-package.ps1
```

以上结果来自本次 Windows 构建及隔离检查，不继承旧身份的验证结论。

## Windows 交付命名

可执行文件为 `Frog.exe`，ZIP 为 `Frog-windows-x64.zip`，解压根目录为 `Frog/`。CMake、版本资源、构建／安装／卸载／性能脚本、文档已同步；安装包验证同时检查 ZIP 文件名和全部条目名仅含 ASCII。安装脚本继续识别旧版中文可执行名以完成升级，交付内容使用英文名。

本次已在 Windows 环境重新构建，并通过安装包验证。
