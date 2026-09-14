# 青蛙导航 Windows

> 项目内部身份已统一为 Frog，桌面显示名为“青蛙导航”。新版使用独立数据目录与备份格式，导入备份时须符合当前 `frog-bookmarks` 格式。

Windows 11 x64 原生书签启动台。使用 C++20、Win32、Direct2D / DirectWrite，界面基于 `designs/frog-windows-launchpad/` 原型。完整功能以本地文件为基础，离线可用；书签备份与 macOS 客户端共用格式版本 1。

## 运行与安装

解压 `Frog-windows-x64.zip`，进入 `Frog/` 目录，双击 `Frog.exe` 即可运行。交付文件与目录名只使用 ASCII 字符，界面名称显示“青蛙导航”。安装到当前用户目录：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

默认位置为 `%LOCALAPPDATA%\Programs\Frog`，安装后开始菜单提供启动和卸载入口。更新前从托盘退出旧进程，再从新 ZIP 解压目录运行安装脚本。更新检查文件指纹并保留原版本直至替换成功，失败时恢复原版本。登录启动默认关闭，更新保留已有注册。无需管理员权限，不依赖独立 VC++ 运行库安装。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

卸载只移除经安装标记验证的程序目录及本应用快捷方式，保留书签、偏好、缓存和自选数据目录。安装脚本的 `-InstallDirectory` 支持自选以 `Frog` 结尾的目录；`-NoShortcuts` 用于隔离脚本检查。

## 操作

- 默认 `Ctrl + Alt + Space` 展开或收起；也可使用托盘或重复启动程序。设置可修改、关闭或恢复快捷键，占用冲突会保留旧组合。
- 启动台在鼠标所在显示器铺满工作区，保留真实任务栏，并为自动隐藏任务栏保留唤出边缘。打开网站、切换应用、点击根目录空白或 `Alt + F4` 时收起；托盘或设置 → 关于 → 退出才会结束进程。
- 搜索标题和网址，包括文件夹内书签；方向键选择、Enter 打开。无结果时 Enter 打开输入网址或 Google 搜索。`Ctrl + F` 或 `/` 聚焦搜索，`Ctrl + N` 添加，`Ctrl + ,` 设置。
- 鼠标滚轮、横向滚轮、分页圆点、页面两侧箭头与 `Page Up / Down` 翻页。
- 右键可复制网址、编辑、刷新图标、移动位置和删除。文件夹标题点击后重命名；非空文件夹须先清空。
- 长按图标进入整理，拖动到条目上排序；停留约 650 毫秒创建文件夹或展开目标文件夹。拖到边缘停留跨页，从文件夹拖出面板可移回根目录。Esc 取消拖动。成功落下后保存，失败恢复原视图与数据。
- Esc 按拖动、快捷键录制、面板、整理、文件夹、搜索、收起的顺序逐层处理。收起保留未提交表单。中文输入法组合期间不处理确认、取消和方向快捷键。
- 自绘条目提供 UI Automation 名称、网址、归属、位置、选择与 Invoke；原生输入框和按钮可用键盘操作。跟随系统高对比度和关闭动画设置。

## 数据与恢复

默认文件：`%LOCALAPPDATA%\Frog\Data\bookmarks.json`。偏好为 `%LOCALAPPDATA%\Frog\preferences.json`，图标为 `%LOCALAPPDATA%\Frog\IconCache`。

设置 → 数据与备份可切换目录、另存 JSON、恢复完整备份和重试读取。切到空目录时复制当前数据；已有有效文件时读取它。自选目录只承载书签 JSON 和写入过程中的临时文件，可交给坚果云等外部工具同步。恢复需要校验及确认，然后整体替换。

保存经单一后台队列完成，使用同目录临时文件、FlushFileBuffers、ReplaceFileW，并比较先前的磁盘内容。ReadDirectoryChangesW 监测外部原子替换；冲突时载入最新有效版本并保留草稿，再次点击保存表示在新版本上重试。目录消失、文件损坏、只读或写入失败时不提交界面变更。若替换瞬间发生外部写入，会保留 `.frog-conflict-*.json` 外部版本用于恢复；不要由同步清理工具提前删除这些冲突文件。与不参与协调的同步进程之间不存在跨进程数据库事务，冲突副本是最后保障。

格式：`format: "frog-bookmarks"`、`schemaVersion: 1`、`groups`、`bookmarks`。UUID、创建时间、逻辑顺序、空文件夹和显式 `groupId: null` 均保留。网页端 KV 的数据格式不同，应通过 macOS/Windows 本地备份互通。

图标先读本机缓存，再在后台尝试站点 favicon、HTML 中的图标链接、Google S2。下载最多 2 MB、重定向最多 3 次、最多 2 个工作线程，扫描前 32 个有效图像帧并选择短边最大的图像，按显示尺寸居中裁剪。与 macOS 一致，图片铺满白色底板后统一裁圆角，透明区域不露出灰色占位底板。旧版缓存可继续使用，已缓存的低清图标可右键「刷新图标」重新获取。刷新失败保留旧图；缓存上限约 64 MB，内存最多 128 张图标。收起时清空排队工作、使进行中的任务失效并释放绘制表面；进行中的同步 WinHTTP 调用在短超时内退出，不阻塞 UI。

## 开发与验证

安装 Visual Studio 2022 或 2026，选择「使用 C++ 的桌面开发」、Windows 11 SDK、CMake。首次构建联网下载固定 SHA-256 的 nlohmann/json 单头文件；后续可离线编译。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows/scripts/build.ps1
```

构建前从共享的 `assets/frog-navigation.png` 自动生成 `resources/AppIcon.ico`（16、24、32、48、64、128、256 像素）。保留原图完整构图和背景，关于页复用同一图标。

默认构建 x64 Release，执行核心测试和隔离原生运行测试，然后生成 `windows/dist/Frog-windows-x64.zip`。`-Configuration Debug` 构建调试版，`-SkipPackage` 只验证。`-SkipTests` 用于复用同一源码已通过的检查结果，或确实无法启动桌面的构建环境；后一种情况须记录运行检查尚未通过。原生运行测试会短暂展开自己的隔离窗口。

```powershell
.\windows\build\Release\Frog.exe --offline --data-directory "D:\Frog-测试" --diagnostics "D:\Frog-测试日志.jsonl"
.\windows\build\Release\Frog.exe --background
powershell -NoProfile -ExecutionPolicy Bypass -File windows/scripts/measure-performance.ps1
```

`--data-directory` 自动启用隔离实例，偏好只在内存中保存，使用独立临时图标缓存，禁止修改登录启动；可与正式实例共存。`--offline` 不发出图标请求；`--background` 静默驻留并推迟主界面创建；`--diagnostics [路径]` 写入 JSONL 事件，无路径时使用 `%TEMP%\Frog-diagnostics.jsonl`。

性能脚本生成 1,000 条隔离数据，测量新进程可操作时间、三次再次展开、收起 30 秒后的私有提交内存与工作集，再采样 10 秒 CPU。CPU 以单核 100% 为口径，内存以十进制 MB 比较目标。脚本不清空系统文件缓存；日志和硬件信息位于 `windows/build/performance/`。图形显存计数器不可用时报告为空，不能据此当作零显存。

实际验证结果及需要人工完成的检查见 [VALIDATION.md](VALIDATION.md)。

额外检查：`windows/scripts/verify-package.ps1` 在 `build/verification/` 下验证 ZIP 与隔离安装／更新／卸载；`windows/build/Release/FrogIconProbe.exe windows/build/verification/network` 使用生产图标模块抓取 GitHub 和 Microsoft 图标。网络检查不纳入离线 CTest。
