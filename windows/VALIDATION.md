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

可执行文件为 `Frog.exe`，ZIP 为 `Frog-windows-x64.zip`，解压根目录为 `Frog/`。CMake、版本资源、构建／安装／卸载／性能脚本、文档已同步；安装包验证同时检查 ZIP 文件名和全部条目名仅含 ASCII。安装脚本继续识别旧版中文可执行名以完成升级，交付内容使用英文名。

本次完成静态引用和编码检查；尚未在 Windows 环境重新构建或运行安装包验证。

## SVG 图标与网站直连

2026-09-15 增加 Direct2D SVG 解码，并移除 Google S2 图标兜底。已补充路径渲染、透明度、viewBox 居中裁剪、PNG 往返、无效尺寸与离线缓存测试；网络验收程序加入 DeepSeek 平台链接并强制刷新。

当前仅核对了 Microsoft SDK 的 SVG API 声明、链接依赖及源码差异；本机没有 Windows/MSVC，新增测试及实际 SVG 渲染尚未执行。Windows 上需运行上述构建与 CTest 命令，再执行：

```powershell
.\windows\build\Release\FrogIconProbe.exe windows/build/verification/network
```

检查生成的 `network-report.json` 中三个网站均加载成功，并查看隔离缓存中的 DeepSeek PNG 是否正确显示鲸鱼轮廓及透明背景。
