# Windows 当前验证

## 2026-11-06：原生回声终端重构

本轮以 macOS 当前终端实现为基准，将旧网格启动台替换为 Win32 / Direct2D / DirectWrite 原生终端。按用户要求不包含 Windows 文件夹快跳；macOS Finder 功能不变。旧图标缓存、壁纸和分页模块已退役，旧版验收结果不代表当前版本。

### 构建和交互结果

Windows 11 10.0.26100、MSVC x64 Release 构建成功。执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows/scripts/build.ps1 -SkipPackage
powershell -NoProfile -ExecutionPolicy Bypass -File windows/scripts/measure-performance.ps1
```

CTest **3/3 通过**：`core`、`terminal-features`、`native-smoke`。本轮最终测试总耗时 10.09 秒，原生交互验收 9.69 秒。

- `core`：macOS 数据契约、模型变更、原子存储、外部冲突、监听及热键相关行为。
- `terminal-features`：计算器表达式与错误边界、Edge 书签转换和去重、多配置校验及损坏数据拒绝。
- `native-smoke`：启动真实 `Frog.exe`，使用隔离数据、真实键鼠 `SendInput`、UI Automation、磁盘断言与窗口截图；不是仅调用内部方法的模拟。

原生运行已覆盖：

1. 后台延迟创建窗口、单实例唤起与首次绘制。
2. 文件夹树形展开、搜索结果点击、原生与 UIA 焦点一致性。
3. 三步添加、回退、收起后草稿和光标选区保留。
4. 双字段编辑、取消、校验失败、写入失败保留与重试。
5. 网址剪贴板、外部修改冲突及明确重试。
6. 同组排序、删除确认与取消。
7. 移动时创建新文件夹、重命名、移回根目录、删除空文件夹、真实鼠标拖入文件夹。
8. 计算器表达式、历史、复制、错误，以及设置、帮助、日志缓冲区。
9. 备份、恢复、数据目录切换的真实文件结果。
10. 真实格式 Edge fixture 导入、源文件只读和重复导入去重。
11. 搜索收起清理、编辑草稿保留与正常退出。

验收发现并修复后台文件刷新阻断提交、UIA/COM 嵌套消息泵绕过主循环按键处理的问题。测试中的连续同位置单击按 Windows 双击阈值分隔，避免将单击选择误变成双击打开浏览器；没有改变产品双击打开行为。

### 界面证据

已查看实际原生截图，包含展开树、计算器历史及设置界面。最新证据位于忽略目录 `build/Testing/artifacts/`：

- `application.jsonl`：本轮状态、保存、外部更新与绘制事件。
- `tree-expanded.png`、`tree-reordered.png`：树形列表和整理。
- `add-draft.png`、`edit-failure-retains-fields.png`：提示流与失败保留。
- `calculator-history.png`、`settings.png`、`help.png`、`log.png`。
- `edge-import.png`、`terminal-final.png`。

目录内可能保留旧启动台截图，它们不属于本轮证据。测试输出见 `build/Testing/Temporary/LastTest.log`。

### 性能实测

性能脚本生成 **1,000 个隔离书签**，启动独立进程；没有清空系统文件缓存。硬件为 i7-13700HX、32 GiB 内存，显示设备包含 GameViewer 虚拟显示适配器及 AMD Radeon HD 7670。

| 测量项 | 本轮结果 |
| --- | ---: |
| 进程启动至可操作 | 229.54 ms |
| 应用内部首次绘制 | 112.14 ms |
| 三次重新展开 | 11.09 / 13.36 / 12.39 ms |
| 收起后私有提交 | 31,772,672 字节（约 30.30 MiB） |
| 收起后工作集 | 53,346,304 字节（约 50.88 MiB） |
| 空闲平均 CPU | 0% |
| GDI / USER 对象 | 21 / 29 |

启动、重开、私有提交、空闲 CPU 四项脚本目标均通过。GPU 内存计数器没有返回数据，不据此宣称显存占用为零。原始报告位于 `build/performance/` 本轮时间戳目录。

### 边界与交付

- 数据验证使用隔离目录，不将测试数据写入正式书签或正式偏好；未更新正式安装，未发布本轮版本。
- 单机原生运行不等于所有设备验收。真实多显示器不同 DPI、不同中文 IME 候选操作、屏幕阅读器口述、系统登录启动及不同 Edge 安装布局仍需对应环境人工验收。
- Windows 用 Ctrl 映射应用内 Command 组合；默认全局唤起保留 Ctrl+Alt+Space。平台字体与系统输入组件不同，不宣称跨平台逐像素相同。
- 当前产品与构建说明见 [README.md](README.md)，实现范围见 [Windows 方案](../plans/PLAN_WINDOWS.md)。交付名称为 `Frog.exe`、`Frog-windows-x64.zip`，ZIP 根目录为 `Frog/`。

### 安装包验证

已生成 Release ZIP，并执行 `windows/scripts/verify-package.ps1`：ASCII 命名、ZIP 内 EXE 与 Release 哈希一致、隔离首次安装、更新、旧版中文 EXE 名称升级、未知目录保护、卸载与隔离数据保留全部通过。安装与卸载仅发生在 `build/verification/` 临时目录，未更换正式安装。报告为 `build/verification/package-report.json`。

### 文件夹折角视觉修正

将字体字符 `⌄ / ›` 替换为 Direct2D 线条折角，两种状态共享行中心，笔画宽度为 1.5 个设计单位，不再受字体基线影响。默认 Release 可执行文件被占用，因此在 `build/arrow-review/` 独立构建，没有终止正在使用的程序或覆盖原安装包。

独立 Release 构建成功，已查看 `build/arrow-review/Testing/artifacts/tree-expanded.png`，确认展开折角居中。`core`、`terminal-features` 通过；原生运行的树形展开、焦点和拖放等检查通过，但后续文件操作阶段因“输入框内容与真实键盘输入不一致”失败，本轮不能标为完整回归通过。

### 透明托盘图标

独立 Release 已重新构建。使用 Windows `LoadLibraryEx` / `LoadImage` 从实际 EXE 加载托盘资源 102，16、24、32、48、64、128、256 七档均通过透明角落与不透明主体检查，并已查看 `build/arrow-review/tray-preview.png` 的完整青蛙轮廓。原资源 101 仍用于应用图标。本轮未替换正在运行的版本，未在 Explorer 托盘现场截图；透明效果验证来自实际 Windows 图标资源加载结果。

## 2026-11-06：Windows 重构审查修复

修复本轮保留的八项问题：AltGr 误触发退出、UIA 事件缺失、小写 n 取消删除后误开新建文件夹、旧热键规则迁移、全局热键占用应用及文本快捷键、计算器输入静默变义、拖动悬停计时器反复重置、烟测拖动源空指针。

### 构建与回归

在 `build/review-fixes/` 独立构建 MSVC x64 Release，未覆盖正在运行的版本、默认构建产物或安装包。使用本机 Visual Studio 18 2026 附带的 CMake / CTest，命令等价于：

```powershell
cmake -S windows -B windows/build/review-fixes -G "Visual Studio 18 2026" -A x64
cmake --build windows/build/review-fixes --config Release --parallel
ctest --test-dir windows/build/review-fixes -C Release --output-on-failure
```

完整 CTest **3/3 通过**：`core` 0.38 秒、`terminal-features` 0.22 秒、`native-smoke` 13.22 秒，总计 13.83 秒。随后移除计算器错误文案耦合断言，保留行为与边界断言；重新构建并运行 `terminal-features`，通过（0.43 秒）。

新增核心回归覆盖热键统一校验、旧配置默认回退及启停语义，以及 Unicode 算式、未知字符、超长表达式的无损拒绝。数据解析使用隔离输入，不读取或修改正式偏好。

### 原生交互证据

`FrogSmoke` 使用真实 `Frog.exe`、SendInput、UIA 事件订阅及磁盘结果验证：

- `delete-lowercase-n-cancels-without-new-prompt`：小写 n 取消删除后可以正常输入下一条命令，书签不变。
- `altgr-chord-preserves-process-and-draft`：Ctrl+Alt+Q 不退出，后续字符继续进入原草稿。
- `calc-unicode-paste-invalid-and-overlong-preserved`：真实剪贴板粘贴 `１０÷４` 得到 2.5，`2×3` 得到 6；未知字符与超长算式保留、报错且不进入历史。
- `drag-merge-with-continuous-pointer-motion`：目标中心持续微动（20 ms 间隔），两条根书签仍合并成文件夹；完成后恢复隔离种子数据。
- `uia-focus-structure-events-and-native-input-focus`：键盘选择收到目标虚拟节点焦点事件，展开树收到可读取新增子项的结构事件；原生编辑框拥有焦点时，虚拟选中行不冒领焦点。

旧版对照使用 `build/arrow-review/Release/Frog.exe`，仅执行新增审查回归，不重跑旧验收失败流程。旧版在小写 n 取消删除后进入 `mkdir`，把后续 `:help` 当作名称输入，回归失败；证据位于 `build/review-fixes/Testing/before/application.jsonl`。修复版针对性回归及完整原生流程均通过。

完整运行的诊断与截图位于 `build/review-fixes/Testing/artifacts/`；已查看 `calculator-history.png`。测试报告位于 `build/review-fixes/Testing/Temporary/LastTest.log`；最后一次为单独的计算器行为回归。可单独执行新增场景：

```powershell
.\windows\build\review-fixes\Release\FrogSmoke.exe .\windows\build\review-fixes\Release\Frog.exe .\windows\build\review-fixes\Testing\review-only --review-only
```

### 验证边界

真实 UIA 事件订阅通过不等于已验证 Narrator / NVDA 口述体验；Ctrl+Alt 真实输入验证不等于已遍历所有 AltGr 键盘布局。本轮未现场验证不同中文 IME 候选流程、多显示器 DPI、系统登录启动或托盘显示，未打包 ZIP、未提交或推送；正式书签与偏好未改写。

### 正式安装更新

验收通过后，将本轮 Release 可执行文件覆盖到正式安装目录 `C:\Program Files\Frog`；未打包 ZIP。

- 覆盖前备份完整旧安装到 `frog-navigation-history/windows-install-20261106-163549/`，旧 `Frog.exe` SHA-256 为 `64A74D79…F814C7`。
- 正式 `Frog.exe` 替换后 SHA-256 为 `C81AC519…47D3C`，与 `build/review-fixes/Release/Frog.exe` 完全一致；`README.md`、`VALIDATION.md`、`install.ps1`、`uninstall.ps1` 一并同步。
- 用 `--data-directory` 隔离实例从正式路径启动：`process_started` 与 `data_loaded` 正常，进程稳定运行后正常结束。
- 用真实偏好（数据目录指向坚果云同步目录）只读启动：读取 78 条书签，无 `load_failed`；书签文件与 `preferences.json` 时间戳均未变化。
- 原目录缺少安装脚本要求的 `.frog-install.json`，已按 `install.ps1` 标记格式补齐（`application=Frog`、目标目录、`version=1.0.0`），使后续更新与卸载脚本可正常校验。登录启动快捷方式原先指向同一路径，未改动。
- 既有全局热键为 `Alt+Space`（`modifiers=1`），符合本轮新规则，未发生迁移；本轮未现场验证该组合是否被系统占用。

