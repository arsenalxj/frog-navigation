# Windows 当前验证

内部身份已统一为 Frog。旧身份的原始验收记录归档到项目同级 `frog-navigation-history/20260915-051305/`，不作为本次身份变更的验证结果。

2026-09-15 检查结果：

- CMake 源文件路径、资源和安装打包路径一致；PowerShell 文件保持 UTF-8 BOM。
- 当前 `frog-bookmarks` fixture 已通过 macOS FrogCore 解码与往返测试。
- Windows 原生编译、CTest、安装／卸载脚本运行及交互验收尚未执行；当前机器无 Windows/MSVC/PowerShell。

在 Windows 项目根目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows/scripts/build.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File windows/scripts/verify-package.ps1
```

运行通过后再补充真实结果；此处不继承旧身份的验证结论。

## Windows 交付命名

可执行文件为 `Frog.exe`，ZIP 为 `Frog-windows-x64.zip`，解压根目录为 `Frog/`。CMake、版本资源、构建／安装／卸载／性能脚本、文档和 CI 已同步；安装包验证同时检查 ZIP 文件名和全部条目名仅含 ASCII。安装脚本继续识别旧版中文可执行名以完成升级，交付内容使用英文名。

本次完成静态引用和编码检查；尚未在 Windows 环境重新构建或运行安装包验证。
