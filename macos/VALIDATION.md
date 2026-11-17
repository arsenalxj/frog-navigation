# macOS 当前验证

内部身份已统一为 Frog。旧身份的原始验收记录归档到项目同级 `frog-navigation-history/20260915-051305/`，不作为本次身份变更的验证结果。

## 自定义命令操作统一到底部（2026-11-17）

- 自定义命令列表、搜索、编辑、选项字段、目录浏览、删除、执行及停止确认统一使用主界面同一底部绘制方法，起点 `x=40`、基线 `y=856`，键帽、字体、间距一致。已有操作仍可点击，不新增菜单或业务操作。
- 删除顶部操作行、字段右侧快捷键／浏览入口、目录区导航提示和任务行停止按钮的旧绘制及命中区；内容、字段／目录行选择、任务状态和查看结果入口保留。通用命令输入与文件提示继续使用统一底部提示。
- `swift test --filter 'CustomCommandModelTests|LauncherModelTests'`：**87 项通过，0 失败**。
- 独立 AppKit 验收覆盖 **17 个界面状态、118 项断言（含每个操作的底部位置和不重叠检查）**。实际鼠标点击底部搜索、进列表、复制、副本、编辑、目录浏览／采纳、保存、删除取消、运行、返回、停止／取消／确认、新增；验证键盘 Tab、删除与 Esc 保持原行为。旧顶部操作位置和旧停止按钮位置不再触发操作。
- 截图核验列表、编辑、目录浏览、停止确认及 1000×625 缩放；所有操作点击区位于 `y=845..867` 且不越界。证据为 `build/command-footer-smoke/` 下 `checks.json`、`tests.log`、`native.log` 和 17 张 PNG。使用隔离配置、真实 printf/sleep 进程与原生字段编辑器，剪贴板按归属恢复；未改正式数据。事件为进程内调用而非系统物理注入，临时源码和可执行文件已清理。
- 已重新构建固定签名 arm64 Release，并校验 ZIP 实际解压后的签名与内容一致性。产物 `build/青蛙导航.app`、`build/青蛙导航-macOS-arm64.zip`；构建日志 `build/build-release-20261117-144657.log`，包校验 `build/command-footer-smoke/package-verification.log`。ZIP SHA-256：`9ba5af8817ac0127cbe437238fcbc2c4ed4b62bddc0f793c1f686a0bfcd9533f`。未安装、未提交或推送。

- 随后按用户授权替换 `/Applications/青蛙导航.app`。安装脚本完成旧版 ZIP 实际校验归档、正式包严格签名校验及系统注册刷新；旧版保留为 `build/install-backup/Frog-previous.zip`。正式版与本次构建二进制 SHA-256 一致：`90200172ee7ea8c9caac9a57f76151bb18af931653d65afd9565ae9823b66ff4`，架构为 arm64，签名仍绑定原固定证书 `05A2A276A653099A94D2D9E5E343EDB4FED2ECDD`。未自动启动正式应用、未修改正式数据。

## 快捷键提示去重与精简（2026-11-17）

- 按精简方案移除输入行右侧快捷键串、占宽及重复命中区，原生输入延伸至右侧边界。主界面提示区仅保留关联字段、候选、错误及删除／恢复风险；无内容时不画空框。编辑状态栏不再显示底层搜索信息，状态栏不再重复命令与返回提示。
- 主界面与 calc 底部仅显示当前必要操作及主键；calc 的复制反馈移至结果区，标题和历史区不再重复教程。自定义命令保留原有操作行、选项字段与浏览目录点击入口，缩短按钮文字，移除重复页脚及确认正文中的键位；通用命令／文件提示仍有相应提示。没有新增菜单、按钮、模式或键位，没有修改按键路由。
- `swift test --filter 'LauncherModelTests|CustomCommandModelTests|BookmarkKeyboardTests'`：**95 项通过，0 失败**。
- 原生 AppKit 验收覆盖 **18 个截图状态、102 项断言（含各状态的布局边界检查）**：编辑／搜索、长网址及 1000×625 窗口缩放、字段错误、恢复备份风险、calc 结果／历史、自定义命令列表／编辑／目录／删除／搜索、通用文件提示、停止确认、设置和帮助。验证每个状态只有一个完整输入行命中区，输入框使用释放的右侧空间。
- 实际操作验证原生搜索输入、预填退格、历史回焦和复制反馈；鼠标验证原复制、副本、取消、编辑、保存、目录浏览／采纳、删除取消、搜索进列表、运行、停止取消与确认入口。使用真实隔离 printf/sleep 进程与存储，剪贴板按归属恢复；未改正式数据。事件为进程内路由／原生控件调用，不是系统物理键鼠注入。
- 证据：`build/shortcut-hints-smoke/` 下 `tests.log`、`checks.json`、`native.log` 和 18 张 PNG。已人工核对编辑、搜索、calc、自定义命令、目录、恢复风险、停止确认及缩放截图；临时源码和可执行文件已清理。
- 已重新打包 `build/青蛙导航.app`、`build/青蛙导航-macOS-arm64.zip`；固定证书、arm64、ZIP 解压后严格签名与内容一致性校验通过。构建日志 `build/build-release-20261117-142827.log`，包校验 `build/shortcut-hints-smoke/package-verification.log`。ZIP SHA-256：`31b5efb90601d506c4cfbf92e4a7daffc235345296037a74b539424e44fd8f57`。未安装、未提交、未推送。

## 键盘代码审查六项修复（2026-11-17）

- 固定自定义命令删除确认目标：请求时保存目标快照，确认、标题和正文共用该身份；隐藏窗口导致筛选/游标重置也不会改删其他命令，取消或保存成功时清理目标。
- 目录浏览中点击底部路径会取消未采纳选择、收起候选并恢复原生编辑器。停止确认精确放行 ⌘Q/⌘H，仍阻止 ⌘N、设置等穿透确认的操作。
- 帮助、设置、日志、任务缓冲区直接显示命令错误；下一条命令或离开页面清除即时反馈。`:group` 的根目录/命名文件夹两条成功路径清理旧来源；空搜索 Enter 行为与两处提示共用动作判断。
- `swift test --filter 'LauncherModelTests|CustomCommandModelTests|BookmarkKeyboardTests'`：**95 项通过，0 失败**。新增回归覆盖无筛选/有筛选的删除确认隐藏往返及磁盘目标、原生菜单键放行和确认屏障、目录点击回焦、两种 group 返回路径、辅助页错误反馈生命周期。
- 独立 AppKit 窗口 **18 项检查通过**：真实字段编辑器、鼠标命中区、截图与隔离命令存储，覆盖删除第二条后隐藏重开仍正确删除、点击路径后可真实输入、帮助/设置顶部错误可见、空/空白搜索 Enter 结束输入、设置 Esc 回正确主界面。运行真实 `/bin/sleep`，停止确认中 ⌘H 经原生菜单隐藏且任务继续，⌘Q 经原生菜单触发 applicationWillTerminate；验收退出时清理隔离进程与数据。
- 证据：`build/review-fixes-smoke/` 下 `tests.log`、`checks.json`、`native.log`、场景 PNG。使用进程内事件而非系统物理键鼠注入；未访问正式数据。临时验收源码和可执行文件已清理，未重复运行 OCR 或无关全量测试。
- 已重新构建固定签名 arm64 Release，产物 `build/青蛙导航.app`、`build/青蛙导航-macOS-arm64.zip`；ZIP 实际解压后严格签名与内容一致性校验通过。构建日志 `build/build-release-20261117-115648.log`，校验记录 `build/review-fixes-smoke/package-verification.log`。ZIP SHA-256：`5683471292aac9ebe47f88d9c730d4a346407032928614bfd3f8818fa77f6960`。未安装、未提交、未推送。

## 自定义命令目录浏览与字段导航分离（2026-11-17）

- 根据用户原生验收反馈修正：Tab/Shift+Tab 始终切下一／上一字段；工作目录用 ⌘↓ 或点击“浏览目录”显式打开候选。Enter 采纳后收起候选、恢复路径字段编辑器，随后一次 Tab 直达下一字段。Esc 取消浏览；候选中 Tab/Shift+Tab 关闭浏览并切字段，不采纳高亮项。
- 路径输入不自动读取或展示目录候选；收起时取消读取并清空候选，过期异步结果不能重新打开候选区。方案与使用说明同步采用新契约。
- `swift test --filter 'CustomCommandModelTests|GlobalHotKeyTests'`：**48 项通过，0 失败**。回归覆盖打开目录类型的完整字段顺序、采纳后 Tab、反向切换、取消浏览、异步旧结果及 ⌘↓ 精确保留。
- 独立 AppKit 原生窗口 **18 项检查通过**，使用真实字段编辑器、生产按键路由与视图鼠标命中区；完整覆盖“Tab 到工作目录 → ⌘↓ → 选择 android → Enter → 候选消失且恢复输入 → 一次 Tab 到打开方式”，以及点击浏览、进入 sdk 不改草稿、Esc/Tab/Shift+Tab 收起、保存后重新读取实际目录。
- 截图确认采纳后没有候选区，下一次 Tab 高亮打开方式；证据位于 `build/directory-navigation-smoke/` 的 `checks.json`、`native.log`、`tests.log` 与 `01-path-input.png` 至 `04-next-field.png`。临时源码和可执行文件已清理。验证为进程内事件，未注入系统级物理按键，未访问正式命令数据。
- 已重新打包 `build/青蛙导航.app` 和 `build/青蛙导航-macOS-arm64.zip`；固定证书签名、arm64、ZIP 实际解压签名与内容一致性校验通过。构建日志 `build/build-release-20261117-111508.log`，包校验 `build/directory-navigation-smoke/package-verification.log`。ZIP SHA-256：`96e8e5df40ca5fd00509c48705ac139bedb81d3f46949bd61f8b7a962720ab7a`。未安装或替换正式应用，未提交或推送。

## macOS 键盘操作统一（2026-11-17）

- 按 `plans/PLAN_MACOS_KEYBOARD.md` 实施：两处搜索保留文本焦点、Tab 显式切列表；⌘C 复制／⌘D 命令副本；字段 Tab 导航与 Enter/⌘Enter 保存；calc 历史选择不覆盖草稿；目录浏览不隐式采纳；Esc 不折叠文件夹、不停止进程，停止任务需明确确认。
- `swift test --filter 'LauncherModelTests|BookmarkKeyboardTests|CustomCommandModelTests|GlobalHotKeyTests|TerminalCalculatorTests'`：**115 项通过，0 失败**。覆盖持久化与校验、搜索焦点、目录异步结果、菜单保留组合、任务返回与停止等相关契约；未运行无关完整测试套件。
- 原生截图验收后修正历史焦点／停止确认的旧入口提示，并阻止点击输入区绕过停止确认；对应 `testClickActionsShareSelectionAcceptanceAndStopContracts` **1 项通过**。空命令提交恢复原输入焦点，对应 `testCalculatorClearAndCommandRoundTripRestoreExpression` **1 项通过**。两次定向回归均完成当前应用及测试编译。
- 独立 AppKit 冒烟最终 **35 项断言通过**：真实 NSApplication 事件循环、keyWindow、NSTextView 字段编辑器、字符输入、预填退格、Shift 选区、文字复制优先、组字 Esc 放行、主界面／命令搜索焦点、calc 历史与命令往返、目录草稿保护、停止确认防穿透。使用真实隔离 `/bin/sleep` 子进程确认返回后仍运行、Enter 默认取消停止、y 确认后记录退出状态。
- 原生窗口截图核对主界面、calc 输入／历史、目录候选、停止确认与执行结果；历史焦点显示保留的算式草稿，确认层不再展示无效命令入口。证据：`build/keyboard-smoke/checks.json`、`native.log`、场景 PNG、`tests.log`、`confirmation-regression.log`、`empty-command-regression.log`。
- 冒烟脚本校正了无匹配搜索样本、可见选择目标及合成方向键的原生功能字符；最终运行全部通过。临时源码与可执行文件已清理，截图和记录保留。
- 使用隔离数据目录；冒烟保存并恢复系统剪贴板，不注册全局快捷键、不改正式数据。事件在进程内经过生产路由与原生字段编辑器，**不是系统级物理按键注入**；输入法验证为真实字段 marked-text 状态，不等同于人工完整拼音候选验收。未重新打包、安装、签名或发布，正式已安装应用尚不包含本次改动。

- 随后按用户授权完成 Release 打包（未安装）：首次构建因现有固定证书 `CSSMERR_TP_NOT_TRUSTED` 被阻止；经用户明确授权，只恢复该证书的代码签名信任，未创建新证书或导出私钥。固定证书指纹仍为 `05A2A276A653099A94D2D9E5E343EDB4FED2ECDD`，与已安装版 designated requirement 一致。
- 产物：`build/青蛙导航.app`、`build/青蛙导航-macOS-arm64.zip`。脚本校验固定证书、Bundle ID 和 arm64；ZIP 实际解压后通过严格签名校验，应用内容与构建产物一致。构建日志 `build/build-release-20261117-105302.log`；包校验记录 `build/package-verification-20261117.log`。
- ZIP SHA-256：`6f54d4d8cc52101dbfba6bbb450820bc70e913b882f9c3b8afee251e419520de`；应用二进制 SHA-256：`155482fe842d9dcb103dd4fb030ba1860cb3374e0ddb31edd948b2988015e2d0`。本次未启动 Release 包做人工交互验收，未替换 `/Applications` 正式应用，未提交或推送。

## 三页输入区传统色区分（2026-11-10）

- 按确认的 B 原型实现：主界面艾背绿 `#DFECD5`、自定义命令远天蓝 `#D0DFE6`、计算器杏仁黄 `#F7E8AA`。中文页面名和模式同显；颜色取决于当前页面，而非搜索／命令／编辑输入状态。其他缓冲区保持原样。
- `swift build` 通过。隔离 AppKit 窗口的 11 项焦点与输入检查通过，包括原生字段编辑器输入搜索词、输入 `12*7` 得到 `84`。
- 12 个场景截图经内嵌 ICC 配置转换至 sRGB 后核验输入区、内容区和状态栏的实绘颜色，共 36 个采样通过；覆盖首页、搜索、编辑，命令列表、搜索、编辑、命令输入，计算器输入、结果、命令输入，返回首页及帮助页。直接使用 `NSBitmapImageRep.colorAt` 转色的首次校验存在色彩空间偏差，未据此修改产品色值。
- 证据：`build/native-palette-smoke/` 下的场景 PNG、`checks.json`、`pixels.json`。验收使用真实 AppKit 事件循环及进程内按键路由，不是系统级物理按键注入；正式数据未改写。未重复全量测试，未重新打包或安装。
- 后续去掉输入区与状态栏之间的 4px 白缝：输入区扩展至 `752..796`，文字位置不变；三页真实窗口截图边界采样通过。
- 搜索结果支持通过 `↑↓` / `Tab` 交出输入焦点并保留筛选，随后编辑、移动、复制、删除；搜索快捷提示精简，空查询／无结果／有结果的右侧提示与实际行为一致。真实 AppKit 窗口已分别核验三种提示及输入焦点。
- 首页自定义命令直接执行、不自动跳页。代码审查发现后台长任务取消入口不可达后，已修复为运行期间主动输入 `:commands` 打开当前任务执行页，按 `Esc` 终止。新增回归覆盖终止后下一条命令可正常执行，以及无任务时恢复管理列表。
- 本轮较早的完整 `swift test` 为 **219 项通过**；审查修复后定向 `CustomCommandModelTests` 为 **22 项通过**，未再次运行完整测试。临时验收源码和可执行文件已清理。
- 已完成最新 Release 打包与覆盖安装，固定证书签名、arm64 架构及安装后二进制一致性校验通过。产物 `build/青蛙导航.app`，构建日志 `build/build-release-20261110-111046.log`；安装位置 `/Applications/青蛙导航.app`，旧版已验证并归档至 `build/install-backup/Frog-previous.zip`。未启动正式应用、未改写正式数据。

## 打开目录的 shell 初始化修复（2026-11-09）

- 修复二次启动交互 shell 重读 `.zshrc` 导致工作目录偏离配置的问题。目录动作改为单个交互登录 zsh，按原顺序衔接用户启动文件，在最后一个启动阶段结束后切换目录；保留用户 shell 状态并清理私有临时启动文件。Finder 与其他命令动作不变。
- 新增行为回归在修复前出现 6 个断言失败：目标目录不正确、最终 shell 非登录状态、用户配置重复读取。修复后 `swift test` **216 项通过，0 失败**；覆盖默认 HOME 与自定义 ZDOTDIR、启动文件内 cd、PATH／别名／函数保留、初始化顺序及临时文件清理。
- 生产执行器生成的脚本在真实 PTY 中验证 `.zshenv` 重定向 ZDOTDIR 和 `unsetopt rcs` 两种场景：目标目录正确、交互登录状态保留、初始化顺序正确、临时文件清理、后续命令可主动切换目录。重定向场景还核对首次提示符的目录以及 PATH／别名／函数。记录：`build/directory-startup-fix/verification.json` 及各场景 `pty.log`。
- 一次验收等待 logout 超时，隔离子进程已清理；不将该次正常退出列为验收通过。未重新验证终端 GUI 交接，未重新打包、安装或提交，已有 Release 包尚未包含此修复。临时验收源码和可执行文件已清理。
- 随后按用户授权完成 Release 打包与正式安装：固定签名、arm64 校验和 ZIP 实际解压校验通过，`/Applications/青蛙导航.app` 已更新，安装二进制与构建产物 SHA-256 一致（`739fd21ae15729762a831393ba2bdf8272fd33da446c13bc4cf03f0d815a61d0`）。旧版已验证并归档至 `build/install-backup/Frog-previous.zip`，系统应用注册已刷新。发布包：`build/青蛙导航-macOS-arm64.zip`；构建日志：`build/build-release-20261109-152552.log`。未启动正式应用、未提交代码。

## 打开目录支持 Finder（2026-11-09）

- 「打开目录」的选择字段改为「打开方式」，提供已安装终端与 Finder。Finder 使用 NSWorkspace 指定应用打开文件夹，不生成 shell 脚本；其他动作不能保存 Finder，切换类型自动恢复适用选项。保留原 JSON 字段和已有终端配置兼容性。
- `swift test`：**215 项通过，0 失败**。覆盖 Finder 保存重载、动作限制、选项切换、无终端时仍可选择 Finder、运行参数与无效目录拒绝。
- 独立 AppKit 窗口验证真实输入焦点、键盘选择 Finder、保存重载；截图 `build/finder-directory-smoke/finder-option.png`。生产执行器实际打开含中文、空格、单引号及分号的目录，核对 Finder 前台身份、窗口目标路径和目录内容截图，确认不是仅定位父目录。证据：同目录 `smoke.log`、`finder-window.png`。
- 原型真实浏览器验证 Finder 选择、预览、保存重载，控制台无错误。正式执行无需 AppleScript 自动化；验收读取 Finder 窗口路径前检查已有授权，未请求新权限。
- 未改写正式数据，未重新打包或安装；此前 Release 包不包含本次 Finder 支持。未重新验收各终端 GUI 交接。临时验收源码和可执行文件已清理。
- 随后按用户授权重新打包 Finder 版本：固定证书签名、稳定身份、arm64 架构校验通过；`build/青蛙导航.app` 和 `build/青蛙导航-macOS-arm64.zip` 已更新。ZIP 实际解压核验 16 个条目、签名、内容与权限一致。日志：`build/build-release-20261109-142834.log`；二进制 SHA-256：`b81b1eabb4d47c3fea3fb4418214391dfd77ca159459cddbbdbcb9e230474752`。未安装、未提交。

## 打开目录动作（2026-11-09）

- 新增 `directory`「打开目录」类型，只显示命令名、名称、动作类型、工作目录、终端；保存清除不适用的执行内容及参数。复用现有终端启动链，进入工作目录后运行交互式 zsh，不接受运行参数。
- `swift test`：**209 项通过，0 失败**。覆盖保存重载、旧脚本参数清除、无终端与非法目录拒绝、类型切换及字段导航、运行参数拒绝。
- 独立 AppKit 窗口在 `NSApplication.run()` 中验证 keyWindow、真实 NSTextView 输入、类型切换、目录输入、直接切换终端字段、保存及重载。截图：`build/directory-action-smoke/final/edit.png`，未注入系统级物理按键。
- 生产执行器生成的启动脚本在真实 PTY 中运行，确认中文、空格、单引号与分号目录的实际 `$PWD` 正确、shell 处于交互模式、可执行第二条输入命令，启动脚本自动清理。记录：`build/directory-action-smoke/shell.log`。使用隔离 HOME／ZDOTDIR，不改写正式数据。
- 原型真实浏览器验证新建、五字段编辑、保存重载、目录预览和运行参数拒绝；浏览器错误记录为空。
- 本轮未重新验收 Terminal／iTerm2／Ghostty 的 GUI 交接与自动化授权，未打包、安装、提交。临时冒烟源码和可执行文件已清理。
- 随后按用户授权完成 Release 打包：固定证书签名、稳定身份和 arm64 校验通过；`build/青蛙导航.app` 与 `build/青蛙导航-macOS-arm64.zip` 已生成，ZIP 实际解压验证 16 个条目、签名、内容及权限一致。日志：`build/build-release-20261109-141526.log`；二进制 SHA-256：`42a75ef7ec53df5fd820e25284b65d4720dc9a6b45ac5efbdf0c68f8b389d837`。未安装、未提交。

## Ghostty 标签页复用（2026-11-07）

- Ghostty 执行改为优先复用已运行实例：通过 AppleScript 字典（`new surface configuration` + `new tab in front window`）在当前窗口新建标签页，设置工作目录、启动命令与“命令结束后保留标签”；Ghostty 未运行或脚本失败时才回退到 `--window-save-state=never` 的独立实例，并在结果区注明回退原因。
- 本机 Ghostty 1.3.1 实测：`new tab with configuration` 可用；命令结束后标签保留，原有两个标签保持不变，未产生新 Ghostty 进程。标签页关闭由验收脚本按新增 id 精确关闭，未动原有标签。
- `swift test`：**205 项通过，0 失败**。新增 AppleScript 字面量转义回归（引号、反斜杠、中文与空格路径）。
- 独立验收 **11 项通过**：运行中复用、仅新增一个标签、原有数量与顺序保留、无新实例、指定中文特殊字符目录、参数保持字面值且不执行注入、登录环境解析到真实 `omp`、真实窗口截图、测试标签清理。证据：`build/ghostty-tab-smoke-lHlB2u/verification.json`、`tab.png`。
- 授权与边界：自动化权限以系统状态为准（本机已允许）；拒绝或 `macos-applescript=false` 时回退为新窗口并在结果区提示。未验证多窗口下“front window”选取异常、全屏与多屏场景。
- Release 重建，固定证书签名与 arm64 校验通过；日志 `build/build-release-20261107-174422.log`。未安装、未提交、未改写正式数据。

## 目录浏览 Enter 语义修正（2026-11-07）

- 问题：进入浏览后默认高亮第一项，按 Enter 会把输入路径替换成高亮目录（例如 `assets/`），看起来像“保存”却改了值。
- 现在 Enter 只退出浏览并保留输入框路径，从不应用高亮；选择目录改用 `Tab`（选择并进入）与 `⇧Tab`（上一级），`↑↓` 仅移动高亮，点击候选等同 Tab。提示、脚注、README 与 SPEC 同步更新。
- `swift test`：**204 项通过，0 失败**。浏览回归改写为“Enter 退出不改路径 → 再次 Enter 回到浏览 → Tab 进入 → ⇧Tab 上级并预选 → Tab 继续进入 → Enter 保留 Tab 选择”，并保留草稿与保存断言。
- 原生窗口 **16 项检查通过**：字段模式、进入浏览不改路径、默认高亮不等于选中、Enter 退出不替换草稿、Tab/⇧Tab 往返、保存为 Tab 选中的目录。证据：`build/enter-exit-smoke/verification.json`、`browse-highlight.png`、`tab-selected.png`。
- Release 重建，固定证书签名与 arm64 校验通过；日志 `build/build-release-20261107-173915.log`。未安装、未提交、未改写正式数据。

## 代码审查修复（2026-11-07）

对本次自定义命令改动运行 `ocr review`（17 文件 / 22 条），修复其中高、中风险项；设计原型同步修正。

- 命令页按键不再无条件接管：只有 `commands-edit` / `commands-delete` 提示流由自定义处理器处理。`buffer == .commands` 时启动的 `:backup`、`:restore`、`:cd`、`:delete` 等内置提示流现在能正常显示、提交与取消；提交路径不再被提前拦截。
- 视图层同步收窄：非自定义提示流会绘制输出面板与候选点击区域，`.custom` 命中区域仅对 `commands-` 提示流放行（鼠标与辅助功能一致）。
- 目录浏览修复：⇧Tab 预选改为保存绝对路径；字段编辑器键入会先退出浏览并保留新输入，不再出现“键入后又按 Esc 恢复旧路径”的静默丢弃。
- 命令列表滚轮会同步夹取 `customIndex`，选中行始终在可视窗口内，Enter 不会执行屏幕外命令。
- 后台程序可终止：执行器持有线程安全的进程句柄，执行页 `Esc` 终止并显示退出状态，不再永久占用“正在执行”。
- `pathChoices` 保留用户输入的 `.` / `..` 语义：列出该目录内容，而不是标准化后错列祖父目录。
- 删除确认不再吞掉 ⌘Q、⌘N、⌘, 等菜单快捷键。
- 原型修复：损坏 localStorage 可由下次保存恢复；同一命令连续预览改为按调用序号重挂；命令类型改用 `Object.hasOwn` 校验；示例目录改为 `~/Documents/...`；成功提示与错误分色；帮助 SYNOPSIS 不再宣称种子命令；浮层位置改用 `BV` 布局。
- `swift test`：**204 项通过，0 失败**。新增 6 项回归：命令页内 `:delete` 提示可用且不执行选中命令、`:cd` 提示自动提交、滚轮后选中项可见、⇧Tab 预选非首项目录、`Esc` 终止 `sleep 30`、`.`／`..` 补全语义。
- 原生窗口冒烟 **5 项通过**：命令页内 `:restore` 提示流与路径候选绘制并生成可点击区域，`Esc` 只取消提示流并保留命令缓冲区；截图 `build/foreign-prompt-smoke/foreign-prompt.png`。
- 原型浏览器验证：种子为中性路径；`:gh first` 连续预览两次均生效；损坏存储后保存可覆盖恢复且错误提示清除；`:backup` 提示流显示在命令页上方并可取消；控制台无错误。
- Release 重新构建，固定证书签名与 arm64 校验通过；日志 `build/build-release-20261107-170556.log`。未安装、未提交、未改写正式数据。

## 终端检测、Ghostty 与字段键盘导航（2026-11-07）

- 自动发现已安装的受支持终端（Terminal／iTerm2／Ghostty），与执行器共享 NSWorkspace 应用定位；旧配置指向缺失终端时保留值并标识，不自动替换。本机实际检测到 Terminal 与 Ghostty 1.3.1。
- 编辑字段分两种模式，互不抢键：字段模式 `↑↓` 或 `Tab / ⇧Tab` 切字段（到末尾不循环），`←→`／空格改选项；目录字段按 `Enter` 才进入浏览。浏览模式 `↑↓` 选候选不改输入，`Tab` 深入，`⇧Tab` 返回上一级并预选刚离开的目录，`Enter` 确认并回到字段模式，`Esc` 退出浏览并恢复进入前路径，直接键入则自动退出浏览。类型／终端仍用空格或 ←→ 改值。
- `swift test`：**198 项通过，0 失败**。新增与改写覆盖：Enter 才进入浏览、进入浏览不改路径、浏览中方向键不切字段、Tab 深入、⇧Tab 上级并预选、Enter 确认后方向键恢复切字段、Esc 分层退出与键入恢复编辑；Ghostty 启动脚本真实执行的字面参数、cwd、自清理与失败目录。
- 独立原生 AppKit 窗口完成 **34 项检查**：逐字段 ↑↓ 往返、Ghostty 检测与左右键选择、目录浏览、中文目录深入、退格、`⌘Enter` 落盘与重载。真实启动 Ghostty 新实例，在中文特殊字符目录中以字面参数执行命令并成功运行 `omp --version`（`omp/18.16.0`）；原有 Ghostty（PID 624）未被复用或关闭，只结束测试新实例。
- 另一次独立原生窗口 **20 项检查**专测浏览模式：`READY`／`BROWSING` 状态、Enter 进入、浏览中方向键与字段切换互不干扰、Esc 恢复路径且不取消编辑、Tab／⇧Tab 往返与预选、确认后按 ↑↓ 回到字段切换、`⌘Enter` 落盘，全程未打开系统面板。
- 第一次启动时观察到 Ghostty 命令实例会恢复用户已有窗口；据此增加 `--window-save-state=never`，修正后重新验收通过。
- 证据：`build/directory-browse-smoke-aQQ0xk/verification.json`、`field-mode.png`、`browse-mode.png`、`confirmed.png`；`build/ghostty-final-smoke-uuortB/verification.json`、`launch.json`、`ghostty-window.png` 及 cwd／参数／版本文本。临时冒烟源码和可执行文件已清理；不修改正式命令、书签数据或系统权限。
- 验收边界：使用进程内生产键盘路由与真实 NSTextView，不注入系统级物理按键；未验证 iTerm2 实际启动，未向 OMP 提交任务。Release 构建、固定证书签名与 arm64 校验通过（日志 `build/build-release-20261107-162934.log`），未替换正式安装、未提交代码。

## macOS 自定义命令（2026-11-07）

- 已实现 `:commands` 管理及 `:<名称> [输入]` 真实执行，覆盖 Terminal／iTerm2 配置、无终端程序、HTTP／HTTPS 网址。列表、编辑、删除确认和执行结果按计算器缓冲区风格原生绘制。
- `swift test`：**192 项通过，0 失败**。新增命令存储 10 项、执行器 11 项、模型 4 项；覆盖损坏／未知版本阻止覆盖、外部写入冲突、原子保存、重复及保留名、取消草稿、删除范围、参数注入字面值、真实子进程工作目录／退出码／双流输出及输出上限。历史按键契约改为 `⌥↑↓`；移除依赖固定命令排序的旧补全断言测试。
- 独立原生 AppKit 窗口在真实 `NSApplication.run()` 循环中完成 **24 项检查**：keyWindow／字段编辑器、命令发现、键盘创建保存、预填退格、Tab 往返、Esc 取消、重载、删除取消、字段空白点击、实际程序执行、缺失目录错误及计算器回归。证据：`build/custom-command-smoke-oCc341/verification.json` 与 `empty/list/edit/delete/discovery/program-result/missing-directory/calc/terminal-dispatched.png`。
- 真实 Terminal 通过 NSWorkspace 接收私有 `.command`，在含中文、空格、单引号、分号的隔离目录下写出 cwd；登录交互 shell 解析到 `/Users/arsenalxj/.bun/bin/omp`，`omp --version` 为 `omp/18.16.0`。随后观察到 PID `98693` 的实际命令为 `bun /Users/arsenalxj/.bun/bin/omp`；后续检查该测试 PID 已退出。未向 OMP 提交任务，不将此结果描述为完整会话功能验收。目录／版本证据见同目录 `terminal-cwd.txt`、`omp-path.txt`、`omp-version.txt`。
- 网址动作实际调用默认浏览器；本地服务器收到 `query=%E4%B8%AD%E6%96%87%20%26%20a%3Bb`（原输入 `中文 & a;b`）请求并返回 HTTP 200。执行器仍只报告浏览器交接，不宣称远端页面加载成功。
- `scripts/build-release.sh` 通过；固定 `Frog Local Code Signing` 签名、严格签名校验和 arm64 校验通过。产物 `build/青蛙导航.app`；日志 `build/build-release-20261107-144601.log`。直接启动签名应用，以隔离目录验证 PID `99662` 的数据载入与首轮交互布局，随后停止测试进程；见 `release-startup.json`。
- 临时冒烟源码与可执行文件已清理，保留验收数据与截图。不安装、不提交、不改写正式书签或正式命令配置。未验证 iTerm2 实际启动、系统级物理键盘注入、终端内 OMP 的完整会话操作；程序型不带终端的长任务不提供中止按钮，应由脚本自行退出或在系统中管理进程。


## 收起界面清空搜索（2026-11-06）

- 窗口统一收起入口清空搜索词，退出搜索输入并恢复未筛选列表；编辑草稿、命令输入与文件夹展开状态保留。
- `swift test`：**168 项通过，0 失败**，包含搜索清空及搜索后切入命令时保留命令输入的回归测试。
- 独立原生 AppKit 窗口冒烟通过：搜索输入后关闭重开、选中搜索结果后关闭重开、未提交草稿关闭重开。临时冒烟源码、可执行文件与独立模块已清理。
- Release 已重新打包至 `build/青蛙导航.app` 与 `build/青蛙导航-macOS-arm64.zip`；固定证书签名、arm64 架构及 ZIP 实际解压后的 16 个条目、内容与权限核验通过。应用二进制 SHA-256：`20b646620fca3810fc84a5efa1e072d49f7a875011bf3f3e578df860ef27959b`；构建日志：`build/build-release-20261106-115927.log`。
- 直接启动打包应用，以隔离数据目录验证 PID `14570` 的实际可执行路径、数据载入与首轮界面布局完成；测试进程已退出。证据：`build/search-reset-release-09zdcel2/verification.json`、`startup.log`、`executable.txt`。
- 未替换正式安装、未改写正式数据；打包应用仅验证启动，未执行系统级物理键鼠交互。搜索关闭重开行为由上述原生窗口冒烟及回归测试验证。
- 随后经授权执行 `scripts/install.sh` 替换 `/Applications/青蛙导航.app`；安装签名与二进制一致性校验通过，安装文件 SHA-256 与上述构建产物一致。旧版已验证归档至 `build/install-backup/Frog-previous.zip`。通过 `open -n` 启动后，`lsof` 确认 PID `51447` 的可执行文件来自正式安装位置。

## 单条书签复制快捷键（2026-11-06）

- 列表复制支持小写 `c` 与大写 `C`；选中书签时底部显示 `c 复制链接`，整理模式同步显示。沿用现有复制逻辑，不修改网址或书签数据。
- `swift build` 通过。独立原生 AppKit 窗口在 `NSApplication.run()` 事件循环内验证 **11 个状态通过**：普通浏览、整理、原大写键、文件夹、搜索输入、搜索结果选择、编辑输入、删除确认、命令输入、设置与计算器。
- 实际读取系统剪贴板，确认复制的是当前书签完整网址（含查询参数和片段），切换选中项后复制目标正确；输入框通过原生字段编辑器键盘事件输入 `c`，未触发复制；计算器 `6*7` 的 `c` 仍复制 `42`。验证后恢复测试前剪贴板内容，隔离书签 JSON 字节未变。
- 原生截图确认普通列表与整理模式显示复制提示，输入态与文件夹不显示；提示不越界。证据为 `build/bookmark-copy-smoke-qw9yGQ/verification.json`、`smoke.log` 和各状态 PNG；临时源码及可执行文件已清理。未执行系统级按键注入或完整单元测试。
- Release 已重新打包到 `build/青蛙导航.app` 与 `build/青蛙导航-macOS-arm64.zip`，固定签名及 ZIP 实际解压校验通过；应用二进制 SHA-256 为 `e3f68b9eb70b78ffd33465b646b52763f3366775b598f7266975b0f8cb39ed77`。构建日志：`build/build-release-20261106-110045.log`；未安装替换正式应用。
- 随后经用户授权运行 `scripts/install.sh`，已替换 `/Applications/青蛙导航.app`；严格签名校验通过，安装位置与构建产物的二进制 SHA-256 完全一致。旧版保存为 `build/install-backup/Frog-previous.zip`，实际解压校验 16 个条目、签名、内容及权限均通过。启动时系统先复用了测试副本，关闭该副本后用 `open -n` 启动正式应用；`lsof` 确认 PID `94013` 的可执行文件来自 `/Applications/青蛙导航.app/Contents/MacOS/Frog`。

## 上下文快捷键提示（2026-11-06）

底部按键条不再使用固定列表，直接从当前提示流、输入模式、缓冲区与选中对象绘制；不改变现有快捷键处理和数据格式。

- `swift build` 通过；完整编译仍有原有的 `LauncherModel.swift` 未使用局部变量 `buffer` 警告，本次未修改该处。
- 独立 AppKit 冒烟程序链接当前应用对象，在可见原生窗口中使用隔离数据，经过 `LauncherView.keyDown`、原生输入控件变更通知与真实存储，**45 个状态通过**。覆盖书签／文件夹／展开子项、编辑与校验失败、多步新增与回退、移动与新建组、删除取消、整理保存、搜索输入／点击结果／无结果、命令补全、设置／帮助／日志／任务、计算器与命令／提示流往返。
- 所有状态均检查提示项不重叠且位于 `x=40..1400`；窗口视图截图核对了普通列表、编辑、删除、位置选择、整理、搜索、命令、设置、计算器、恢复与执行中提示。校验失败时保留当前快捷键，执行中不显示提交或取消操作，隔离排序结果与磁盘 JSON 一致。
- 证据：`build/shortcut-hints-smoke-wbof2s/verification.json`、`smoke.log`、各状态 PNG 与 `footer-montage.png`。临时冒烟源码及可执行文件已清理。
- 快捷键录入仅验证其提示状态；未注册或修改系统全局快捷键。未注入系统级物理键鼠事件，未运行完整单元测试，未替换正式应用、改写正式数据或调整系统权限。
- 随后按用户要求执行 `scripts/build-release.sh`：Apple Silicon Release 构建、`Frog Local Code Signing` 固定签名及严格签名校验通过，产物为 `build/青蛙导航.app`；`build/青蛙导航-macOS-arm64.zip` 已更新，实际解压验证 16 个条目、内容与权限一致、签名有效。应用二进制 SHA-256 为 `4a38c2d72aae1ba217a8990a9e38b622594c468b087096dedacbb5917017d6ca`；构建日志为 `build/build-release-20261106-105001.log`。未安装替换正式应用。

## Edge 收藏夹导入（2026-11-06）

仅 macOS：`:import edge [路径]` 只读扫描 Edge 配置，路径压平、同名组合并、全局 URL 精确去重，通过现有串行存储提交；Windows 未增加入口。

- 边界回归：空配置与有效配置并存、仅含不支持协议、损坏子节点、极大排序值下追加，4 项修复前均失败，修复后通过。命令测试覆盖带空格和中文路径、重复导入不改变数据、任一配置损坏时磁盘与内存保持原样。
- `swift test`：**166 项通过，0 失败**。
- Xcode 原生 Release 构建成功，使用 `Frog Local Code Signing`；`codesign --verify --deep --strict` 通过。应用产物为 `build/edge-import-build/Build/Products/Release/青蛙导航.app`，未替换已安装应用。
- 独立 AppKit 冒烟程序链接当前应用对象，以隔离目录执行真实 `LauncherView` 按键入口、原生输入控件变更通知、命令处理和存储：首次新增 1 条、新建 4 组、跳过重复 2 条及不支持 1 条；再次导入新增 0 条、跳过重复 3 条，源文件字节未变，持久化结果与模型一致。
- 离屏原生渲染已检查：导入结果、重复导入结果、压平目录展开和设置命令入口；证据为 `build/edge-import-smoke-wgsu6fxr/import-success.png`、`import-repeat.png`、`import-folders.png`、`import-settings.png`。临时冒烟源码及可执行文件已清理。
- 本机真实 Edge 数据仅在内存中试导入：1 个配置、239 条书签、13 个组，重复导入新增 0 条、跳过重复 239 条；未写入正式青蛙导航数据。
- 直接启动签名 Release 的独立 PID，使用 `--data-directory` 载入隔离数据成功（`release-startup.log`）。捕获时窗口已收起，未取得 Release 窗口截图。当前进程辅助功能和按键注入权限为未授权，未请求系统权限；不将进程内按键路由与离屏渲染等同于真实窗口物理键鼠验收。测试进程已退出。

## 计算器（2026-11-05）

`:calc` 计算器缓冲区已按 `designs/frog-echo-tui/SPEC.md` 落地：四则运算与小括号、12 位有效数字、最近 50 条去重历史、按列表顺序的 `↑/↓` 选择、`c` 复制、中文括号归一化；`Esc` 关闭后保留算式与历史，`:calc clear` 清空。

- `swift test`：**156 项通过，0 失败**。新增解析器 6 项覆盖运算优先级、括号、一元负号、浮点格式化、全角括号、指数回填、长度上限、除零与语法错误；模型 8 项覆盖输入过滤、历史往返、选中复制、无结果复制、清空、`:命令` 往返、prompt/异步保存后恢复输入、`:calc` 反馈与关闭重开保留算式。
- 评审修复：两端支持指数结果回填（`e/E`）、算式长度上限 256；prompt 与异步命令结束后恢复计算器输入；`:calc` 错误与清空改进底部反馈；历史超过 16 条时按选择滚动；点击历史行不再被旧光标覆盖；计算器场景 id 不再重复；空算式错误优先显示。
- `swift build`：debug 构建通过。离屏渲染 `LauncherView` 核对标题、结果、选中历史行、命令行 `= calc › 算式` 与 `Esc` 提示；预览为 `build/calc-preview.png`。
- 未在真实窗口注入键盘事件：隔离进程会注册全局快捷键并铺满屏幕，未擅自启动；按键路由、粘贴过滤与剪贴板写入由模型/解析测试覆盖，真实窗口交互仍待一次人工验收。

## 文件夹树形展开（2026-11-05）

取消“进入文件夹”，改为根目录原地展开／折叠：`Enter`／`Tab`／双击或点击展开符切换，`z` 全部展开或折叠，`Esc` 从子项折叠父组、再折叠全部、最后收起窗口。展开状态按文件夹 id 保存在本机偏好，删除文件夹后自动清理。

- `swift test`：**139 项通过，0 失败**；新增或改写用例覆盖原地展开、空文件夹展开、Esc 分层折叠、全部展开切换、浏览态 Tab、展开态持久化与失效 id 清理。
- `swift build`：debug 构建通过；用 `--data-directory` 隔离数据（3 个文件夹／9 条书签，均为 UUID）启动真实应用。
  - 根目录渲染：文件夹置顶、行号固定、展开符与项数、根书签编号正确（`build/tree-expand-root.png`）。
  - 展开渲染：子书签缩进、连接线、`已展开` 标记、状态栏展开计数与 `z` 按键提示正确（`build/tree-expand-expanded.png`）。
  - 展开态截图通过临时环境开关预置后立即移除，最终二进制不包含该开关；当前进程的辅助功能权限为未授权，未用脚本注入键盘事件，避免触发系统授权弹窗。
- 界面修正（同日）：移除列表行号（`:open` 只作用于当前项）、文件夹图标放大到 20 与书签底板同尺寸、补上浏览态 `Tab` 展开／折叠并在其他状态消费该键。随后又收紧展开符与文件夹图标的间距、把子项连接线对齐文件夹图标、去掉空闲态假光标并让命令行占位符与真实输入共用起点。修正后 `swift test` 139 项通过；真实应用截图确认无行号、图标同尺寸、行内间距与命令行起点一致。随后移除 `F1` 命令地图及其 `:atlas` 命令与缓冲区状态，命令发现只保留 `?` 帮助与 Tab 补全；移除后 `swift test` 139 项通过。
- OCR 审查修复：数据载入前不再清理已保存的展开态；缓冲区打开时 `Tab` 不再切换被遮挡的文件夹；`:group` 清理缓冲区与搜索词后再定位；拖到文件夹行会展开目标并只在落盘成功后持久化；合并提示要求来源为根书签；帮助页键位补上 `Tab` / `z`。`swift test` 142 项通过。状态栏随后移除固定“根目录”与选中位置/行数（展开时行数会变化、行号已移除），仅在有展开或搜索时显示对应状态。
- 未在真实界面覆盖：`Enter`／`Tab`／`z`／`Esc` 的实机按键、鼠标双击展开、拖拽跨组与创建文件夹。这些路径由模型测试覆盖，仍需一次授权后的人工或辅助功能验收。

## 回声终端重构（2026-11-05）

界面从 Launchpad 网格改为 `designs/frog-echo-tui/SPEC.md` 的原生回声终端；移除网站图标抓取模块与旧分页／弹窗界面，保留原有 JSON 存储、全局快捷键、屏幕触角和 Finder 目录快跳。

- `swift test`：**136 项通过，0 失败**（FrogCore 21、FrogTests 115）；覆盖草稿回退与取消、原子新建／移动、外部冲突、真实备份恢复与目录切换、设置页单字母无动作、命令地图、输入法事件转交、缓冲区 `/`/`?` 快捷键与超大行号不崩溃。
- `./scripts/build-release.sh`：Release 构建、固定证书签名、arm64 与严格签名校验通过，产物 `build/青蛙导航.app`；包内 `Resources/terminal-*.svg` 已就位。
- 真实隔离运行（`--data-directory` 指向 `build/terminal-validation-2026-11-05T04-52-03-426Z/data`，37 条书签／5 个文件夹）：
  - 窗口层级 25（高于菜单栏 24 与程序坞 20），窗口 `y=0` 且高度等于整块屏幕；整屏截图确认菜单栏与程序坞都被界面覆盖，收起后恢复。
  - 主列表渲染、选中、状态栏位置计数、日志与按键条与设计一致（`main.png`）。
  - 命令行输入框按字形实测下移 4pt 后，输入文字、提示符与占位符视觉中心对齐（772.0 与 772.5 设计像素），光标与文字共用一条基线。
  - `,` 打开设置缓冲区；三列布局、`file` 显示当前 `bookmarks.json`、数据操作独立分区、右下角统一提示（`settings.png`）；单字母不改变设置。
  - `:set corner right-up` 生效并写回真实触角控制器；`e` 进入编辑后光标停在末尾、退格逐字删除、Tab 切换字段不覆盖另一字段；`a` 添加书签并保存中文标题（`edit.png`）。
  - `m` → 新建文件夹 → 名称步骤一次原子保存。该轮双击文件夹仍进入独立视图并显示面包屑（`folder.png`）；同日已改为原地展开，见上一节。
  - `:backup "<含空格路径>"` 生成真实 JSON；`:restore` 整份替换后与备份逐字节一致；`:cd` 切换目录后旧目录文件保留、新目录写入同一数据。
  - 切换到其他应用时窗口收起；重新展开后编辑草稿与文本选区保持不变；`:q` 正常退出（exit 0）。

- 打包与安装（2026-11-05）：分发包 `build/青蛙导航-macOS-arm64.zip` 经 `installer_archive.py archive --replace` 实际解压复验，签名、文件内容与权限一致；二进制 SHA-256 `9e555f6c…881881`。已用 `scripts/install.sh` 替换 `/Applications/青蛙导航.app`，旧版归档为 `build/install-backup/Frog-previous.zip`。安装后启动 PID 38290，二进制路径为安装位置，签名校验通过，真实数据 46 条书签／8 个文件夹正常显示，窗口层级 25 覆盖整屏。

未在本次验证中覆盖：真实 Finder 快跳跨应用流程、登录项重置后的真实登录、后台全局快捷键与屏幕触角物理触发、多显示器和其他应用全屏。这些仍需要真实系统操作验收。

## 早期记录

2026-09-15 验证结果：

- `swift test`：159 项通过，0 失败。
- Release 构建完成，arm64 架构、签名校验通过；应用包 `build/青蛙导航.app`，Bundle ID `cn.arsenalxj.Frog`，进程 `Frog`。
- 临时目录安装、同身份更新、别名更新、失败回滚、不同身份保护和归档还原校验通过。
- 数据副本转换工具 6 项测试通过，真实旧版 fixture 已转换并匹配当前跨平台 fixture。
- 2026-09-15 已完成正式安装替换并启动；真实界面已检查主书签页、坚果云数据目录、关于页新图标和设置状态。Finder 快跳保持开启，但新身份需要重新授权辅助功能，尚未验证真实跨应用跳转。登录时启动界面显示关闭，未进行注销／登录验收。

## 正式安装交付

已安装 `/Applications/青蛙导航.app`，Bundle ID `cn.arsenalxj.Frog`。安装包与构建文件清单一致，严格签名校验通过；分发包为 `build/青蛙导航-macOS-arm64.zip`，已实际解压校验签名及文件一致性。

25 个书签、5 个文件夹保留，继续使用原坚果云目录。主数据只转换格式标识，书签、文件夹与排序内容保持一致；本机快捷键、屏幕触角、Finder 快跳开关与页码偏好已复制并在启动后核验，Dock 固定入口在原位置更新。

旧应用、原书签和偏好已归档到项目同级 `frog-navigation-history/install-20260915-053410/`；旧版 ZIP 已实际解压并验证。应用目录中的旧版本已移除。安装及启动证据见 `build/installed-verification.json`，归档记录包含恢复所需原始数据。

## SVG 网站图标

2026-09-15 新增 SVG 解码、透明度与 PNG 缓存回归用例后，`swift test` 全部 162 项通过。DeepSeek 平台实际抓取生成 256 × 256 透明 PNG，离线缓存复用通过；安装后的应用界面已确认显示鲸鱼图标。

## 固定本机代码签名

2026-09-15 已在登录钥匙串创建并配置代码签名专用自签名身份 `Frog Local Code Signing`，证书有效期至 2036-09-12，SHA-1 指纹为 `05A2A276A653099A94D2D9E5E343EDB4FED2ECDD`。私钥保存在登录钥匙串，仓库不保存私钥。证书设置脚本重复运行会复用已有身份；缺失证书时构建脚本已验证会停止。

命令行脚本和 Xcode 的 Debug／Release 均改为固定证书签名。构建号 1 与 2 的 Release 实际构建通过，arm64 架构、严格签名及实际签名证书指纹均通过校验。两次 CDHash 分别为 `052cee002731140187a6a427a9762bf8393b11c0` 与 `fc163fc936b213888a46e1206d4101faf23e0100`，两者的身份要求一致，并通过双向身份要求校验：

```text
identifier "cn.arsenalxj.Frog" and certificate leaf = H"05a2a276a653099a94d2d9e5e343edb4fed2ecdd"
```

用户已将旧辅助功能条目移除并重新添加首个固定签名版本；重启后，应用实际权限检查中的辅助功能、Finder 自动化、键盘控制与监听均通过。随后退出并安装构建号 2，全程未再次操作系统权限；新进程的权限检查仍通过，相关提示均未出现。安装包与构建产物文件清单一致，书签文件 SHA-256 未变，更新后的 TCC 日志未出现旧身份要求不匹配错误。当前正式安装为固定证书签名的 1.0.0（2）。

TextEdit 标准打开面板的补充自动化验证中，Control-G 未观察到目录变化，尚未形成真实跨应用快跳成功证据；不能把权限保持通过等同于完整交互验收通过。本次未改动快跳实现。证据保存在 `build/signing-validation/verification.json` 与 `build/signing-validation/tcc-after-update.log`。

## 隐藏程序坞图标

2026-10-28 改为 AppKit `.accessory` 激活策略，并在应用包声明 `LSUIElement = true`；设置、安装提示和使用说明同步移除程序坞唤起入口。

- `scripts/build-release.sh` 成功；固定证书签名、arm64 架构及严格签名校验通过，产物为 `build/青蛙导航.app`。
- 直接运行 Release 可执行文件，以 `--data-directory` 和 `--offline` 隔离验证。手动启动时实际激活策略为 `.accessory`，一个启动台窗口可见且获得激活，截图已检查；切换到 Finder 后窗口收起，进程继续运行且激活策略不变。
- 以 `--background` 启动同一产物，实际激活策略仍为 `.accessory`，没有可见窗口且未激活；生成包内 `LSUIElement` 为 `true`。隔离进程均已退出，未替换正式应用或修改程序坞配置。
- 隔离验证时本机原有正式版仍在运行，且程序坞已固定该应用。Finder 重新打开按 Bundle ID 路由到了原有正式版，未能据此验证隔离进程重开；定向重开事件缺少自动化授权，未请求授权。
- 未验证真实登录、快捷键、屏幕触角和键盘交互；本次未运行单元测试。证据为 `build/dockless-qa-5l74fkbc/verification.json`、运行日志和 `manual-launch.png`。

### 正式安装与重新打开

2026-10-28 经用户授权，正常退出旧版后通过 `scripts/install.sh` 替换 `/Applications/青蛙导航.app`。安装及签名检查通过，旧包已归档并验证，回滚文件为 `build/install-backup/Frog-previous.zip`。

- 从正式安装路径启动成功，实际激活策略为 `.accessory`，包内 `LSUIElement = true`；真实界面显示原有书签，截图确认程序坞中没有青蛙导航图标。
- 切换到 Finder 后启动台收起；再通过系统打开正式应用，复用同一进程及原窗口，激活策略保持不变。
- 安装前后书签文件 SHA-256 一致，应用偏好没有变化。未手动修改 Dock 设置；安装启动后查询，原有固定项已不在 Dock 配置中，无需额外移除。
- 证据为 `build/dockless-qa-5l74fkbc/installed-verification.json` 和 `installed-launch.png`。新版保持运行；未验证真实登录、快捷键和屏幕触角。
