# 青蛙导航 Windows

Windows 11 x64 原生、离线优先书签启动台，使用 C++20、Win32、Direct2D / DirectWrite。界面按 macOS 的“回声终端”重构：1440 × 900 设计坐标等比缩放，树形单列表、底部命令行、日志与缓冲区，不嵌入网页运行时。两端共用 `frog-bookmarks` 版本 1 数据格式。Windows 不提供文件夹快跳。

## 运行与安装

解压 `Frog-windows-x64.zip`，进入 `Frog/`，双击 `Frog.exe`。交付文件名只使用 ASCII，界面名称为“青蛙导航”。安装、更新、卸载仍使用包内脚本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

默认安装到 `%LOCALAPPDATA%\Programs\Frog`，无需管理员权限或独立 VC++ 运行库。更新前从托盘退出旧进程；安装脚本验证目标并保留可回滚的旧版本，失败时恢复。卸载保留书签、偏好、自选数据目录及旧版本已有缓存，不清理用户数据。

## 界面与操作

- 窗口在鼠标所在显示器铺满整块屏幕；无任务栏按钮，不改变任务栏配置。收起后恢复其他应用。默认 `Ctrl+Alt+Space` 展开／收起，重复启动转交现有实例，托盘提供展开、设置和退出。
- 列表固定可视 19 行，超出时滚动，不再分页。根目录文件夹置顶、顺序固定；Enter、Tab、双击原地展开／折叠，子书签缩进显示。展开状态保存在本机偏好，不写入书签或备份。
- 单击整行选中并将键盘焦点交给列表；双击打开书签或切换文件夹。搜索覆盖所有文件夹，点击结果后可以直接编辑、移动、复制。无结果时 Enter 打开输入网址或使用 Google 搜索。
- 图标为标题首字符加传统色底板，颜色按 ID 与 macOS 使用相同稳定算法生成。没有网站图标下载、缓存、刷新命令或壁纸读取。
- 增删改、设置、数据操作都在底部命令行完成，没有表单弹窗。修改原子保存成功后才更新界面；失败保留输入并显示原因。中文输入法组合期间不抢占确认、取消和方向键。
- 下方显示最近三条日志，`:log` 查看本次运行最近 200 条；底部按键提示随当前输入步骤、选中对象和缓冲区变化。

| 按键 | 行为 |
| --- | --- |
| `j/k`、`↑/↓` | 移动选择 |
| `g/G`、`Home/End` | 首项／末项 |
| `Page Up/Down`、滚轮 | 按屏／按行滚动 |
| `Enter` | 打开书签、展开／折叠文件夹或提交输入 |
| `Tab`、`z` | 当前文件夹展开／折叠；全部展开／折叠 |
| `/`、`Ctrl+F` | 搜索 |
| `:` | 输入命令，Tab 补全，↑↓ 命令历史 |
| `a`、`Ctrl+N` | 添加书签 |
| `n` | 新建文件夹 |
| `e/r` | 编辑书签／重命名文件夹 |
| `m` | 移动书签 |
| `D` | 删除所选项，`y` 确认，Enter／N／Esc 取消 |
| `c/C` | 列表复制完整网址；计算器复制结果；文本输入中按文字处理 |
| `o` | 开始／结束整理 |
| `Shift+↑/↓`、`K/J` | 整理模式下同组书签上移／下移 |
| `,`、`Ctrl+,` | 设置缓冲区 |
| `?` | 帮助 |
| `Esc` | 取消输入、退出缓冲区／整理、清空搜索、折叠文件夹、收起 |
| `Ctrl+H`、`Alt+F4` | 收起；未提交草稿与选区保留 |
| `Ctrl+Q`、`:q` | 完全退出 |

整理只调整书签，同组边界不循环，文件夹不参与排序；搜索结果不可排序。可拖动书签到前后位置或文件夹，根目录书签拖到另一个根书签中央停留 550 毫秒后松开会合并成新文件夹。拖动时列表边缘可滚动，Esc 取消。非空文件夹必须先移出或删除子书签才能删除。

## 命令和提示流

| 命令 | 行为 |
| --- | --- |
| `:add` | 网址 → 标题 → 位置；可选择新建文件夹并与书签一次保存 |
| `:edit [title\|url]` | 预填当前值，Tab／Shift+Tab 切换字段，Enter 一次保存两项 |
| `:mkdir [名称]`、`:rename` | 创建空文件夹／重命名；不允许同名 |
| `:move`、`:delete` | 选择目标位置／确认删除 |
| `:open`、`:copy` | 打开当前项／复制当前书签网址 |
| `:group <名称>`、`:find <词>` | 展开并定位文件夹／跨组搜索；`:group 根目录` 折叠全部 |
| `:calc [clear]` | 计算器／清空算式与历史 |
| `:backup [文件路径]` | 导出当前完整 JSON 副本 |
| `:restore [文件路径]` | 校验并整体替换全部书签和文件夹，不合并 |
| `:cd [目录]`、`:set data <目录>` | 切换数据目录 |
| `:import edge [数据目录]` | 只读导入 Microsoft Edge 收藏夹 |
| `:set [login\|hotkey\|corner\|data] [值]` | 设置；无参数打开设置缓冲区 |
| `:help`、`:log`、`:retry`、`:clear`、`:q` | 帮助、日志、重试读取、清日志、退出 |

新增和移动过程中 Tab／↑↓ 切换候选，只有 Shift+Tab 返回上一步；Backspace 只删字。回退保留尚未提交的标题、文件夹名和位置。预填和切换字段时光标在末尾，不自动全选；整段替换用 Ctrl+A。编辑过程中点击背景条目不改变编辑对象。文件夹手工名称上限 60 字，书签标题上限 120 字。

路径支持空格、成对引号、`~` 和真实文件／目录补全；相对路径基于当前数据目录。`:backup` 默认建议“文档”目录下的 `青蛙导航-Bookmarks-YYYYMMDD-HHmmss.json`，用户确认后保存，不能覆盖当前主数据文件。

### 计算器

支持数字、小数、`+ - * /`、小括号、指数形式；中文括号自动转换。Enter 或 `=` 计算，结果按 12 位有效数字输出；错误不进入历史。算式上限 256 字，历史最多 50 条，同一算式只保留最新一条。

↑↓ 按显示顺序选择历史并回填，点击历史同样生效；`c` 复制选中历史或当前结果。原生输入支持光标、选区、Ctrl+A 和中文输入法。Esc 关闭保留本次运行的算式和历史，再次 `:calc` 恢复；`:calc clear` 清空。

### Microsoft Edge 收藏夹导入

默认读取 `%LOCALAPPDATA%\Microsoft\Edge\User Data`，也可指定 Edge 数据目录、单个 profile 或 `Bookmarks` 文件。只读取收藏夹栏和其他收藏夹，不读取其他根节点。

嵌套文件夹压平为路径名称，空文件夹保留，同名组合并；多个 profile 加 `[Default]`、`[Profile 1]` 等前缀，访客与系统配置忽略。URL 按字符串精确去重，已有书签的标题、ID、位置不变。仅导入有效 http/https；空标题用网址，过长标题和组名保留尾部并截到 120 字，保留有效 Edge 创建时间。

所有配置先解析成功，再经串行存储一次原子提交；任何配置损坏、不可读、超过 32 MB 或写入失败，不会部分导入。任务缓冲区显示新增书签、新建文件夹、重复和不支持网址数量。源文件始终只读，重复导入不会新增相同网址。

## 设置与后台运行

- `:set hotkey on/off/reset/record`：启停、默认或录入全局组合。至少包含 Ctrl、Alt、Win 之一；冲突保留旧配置，错误显示于设置和日志。
- `:set corner on/off/left-up/left-down/right-up/right-down`：默认左下角，触角只展开不收起。移开后才能再次触发；启动或重新配置时鼠标已在角落不会误触发。通过鼠标事件驱动，静止不轮询。
- `:set login on/off/approve`：当前用户启动目录快捷方式；读取真实注册／系统禁用状态，approve 打开 Windows 启动应用设置。登录后通过 `--background` 静默驻留，首次唤起才创建窗口。
- 完全退出后热键与触角失效。Windows 按本次范围不实现文件夹快跳，也没有对应设置项或 Ctrl+G 拦截。

## 数据与同步

默认数据：`%LOCALAPPDATA%\Frog\Data\bookmarks.json`；偏好：`%LOCALAPPDATA%\Frog\preferences.json`。偏好包含数据位置、热键、触角和展开的文件夹 ID，不随备份或同步传输。旧版分页和主题偏好不再使用。

切换到空目录时复制当前已保存数据；已有有效文件时直接读取，不改写原内容；失败保留原目录和数据。自选目录可交给坚果云等工具同步，应用本身不做网络同步或并发合并。

保存使用串行队列、同目录临时文件、FlushFileBuffers 和 ReplaceFileW，提交前比较磁盘内容。ReadDirectoryChangesW 监听外部原子替换；冲突载入最新有效版本，保留草稿，用户核对后 Enter 重试。外部文件暂时缺失或损坏时不覆盖。极端外部写入竞争保留 `.frog-conflict-*.json` 副本，勿提前清理。

JSON 保留 UUID、创建时间、逻辑顺序、空文件夹和根书签显式 `groupId: null`；可与 macOS 互相恢复。

## 构建与隔离验收

需要 Visual Studio 2022／2026 的 C++ 桌面开发工作负载、Windows 11 SDK 和 CMake。首次构建下载固定 SHA-256 的 nlohmann/json，后续可离线编译。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows/scripts/build.ps1
.\windows\build\Release\Frog.exe --data-directory "D:\Frog-测试" --diagnostics "D:\Frog-测试日志.jsonl"
powershell -NoProfile -ExecutionPolicy Bypass -File windows/scripts/measure-performance.ps1
```

默认构建 x64 Release，执行 `core`、`terminal-features`、`native-smoke`，然后生成 ZIP。`-SkipPackage` 不打包；`-SkipTests` 不代表验收通过。真实桌面验收使用 SendInput、UI Automation 和截图，需要解锁的交互桌面，期间不要操作测试窗口。

`--data-directory` 使用隔离实例，偏好仅在内存，默认不启用全局热键和触角，禁止修改登录启动；不接触正式书签或正式偏好。`--background` 静默启动；`--diagnostics [路径]` 输出 JSONL。旧 `--offline` 图标下载开关随网络图标模块删除，管理功能本来就可离线使用。

应用图标仍仅由共享 `assets/frog-navigation.png` 等比生成。`build/` 和 `dist/` 为忽略的可重建产物；实际通过项与未验证边界见 [VALIDATION.md](VALIDATION.md)。本次重构不自动提交、安装或发布。

托盘使用独立 `TrayIcon.ico`：同一源图中与画布边缘连通的近白背景转为透明，再完整等比缩放为 16–256 像素资源；保留青蛙内部浅色区域。`generate-icon.ps1` 同时重建应用与托盘资源，应用图标和共享源图不改变。
