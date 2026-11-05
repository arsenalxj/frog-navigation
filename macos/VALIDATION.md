# macOS 当前验证

内部身份已统一为 Frog。旧身份的原始验收记录归档到项目同级 `frog-navigation-history/20260915-051305/`，不作为本次身份变更的验证结果。

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
  - `m` → 新建文件夹 → 名称步骤一次原子保存；双击文件夹进入后显示面包屑、固定添加入行与组内书签（`folder.png`）。
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
