# 青蛙导航「Finder 目录快跳」方案

## 1. 目标与交互

在 青蛙导航 原生 macOS 应用中增加 Finder 目录快跳功能：系统文件选择窗口下方显示目录入口，点击或按 `Control + G`，让该窗口进入 Finder 最后活动的目录。

首版为其他应用的 macOS 系统标准打开、保存和选择文件夹窗口提供快跳，包括浏览器调用的标准面板。自绘文件选择器不在首版范围内。

### 后台行为

- 功能开启且 青蛙导航 运行时生效，收起到后台后继续工作，完全退出后失效。
- 复用现有后台进程，由应用入口统一管理功能启动、暂停和停止。
- 显示和点击目录入口时不展开启动台，并保持目标应用的操作上下文。

### 设置开关

- 在“设置 → 通用”增加独立的“Finder 目录快跳”功能开关，统一控制目录浮条和 `Control + G` 快捷键，默认关闭。
- 开启时检查权限，权限齐全后立即启动功能；缺少权限时在该设置项下显示授权入口，授权完成后生效。
- 关闭时立即隐藏浮条、取消正在进行的导航，并停止本功能的 Finder 目录追踪、文件面板观察和快捷键监听。
- 开关状态仅保存到本机，重启 青蛙导航 后恢复；恢复为开启时重新检查权限。隔离运行不持久化开关状态。

### 目录入口

- 文件选择窗口出现且存在有效目标目录时，在窗口下方居中显示一条入口，例如：

  `📁 项目目录（Finder）    ~/Documents/项目目录    ⌃G`

- 点击整条入口或按 `Control + G`，让当前文件选择窗口进入目标目录。
- 只切换目录，最终打开、保存或确认选择仍由用户操作。
- **没有有效 Finder 目录时完全隐藏入口，不显示占位或提示文案，`Control + G` 也不拦截。获取到有效目录后再显示入口并启用快捷键。**
- 浮条跟随窗口移动、缩放；切换应用或关闭文件面板时隐藏。
- 下方空间不足时改放上方；两处均无空间时隐藏浮条，但在仍有有效目标目录且面板可操作的情况下保留快捷键。

### Finder 目录规则

- 取最后活动的 Finder 窗口当前标签页中的真实目录，不把选中文件当作当前目录。
- 最后有效目录仅在本次 青蛙导航 运行期间缓存，关闭 Finder 窗口后仍保留；青蛙导航 退出后清空。
- Finder 的“最近使用”、搜索结果等虚拟位置不覆盖最后有效目录。
- 缓存目录已失效时不作为可跳转条目展示，例如目录被删除或所在外置盘断开。

## 2. 技术实现

采用 AppKit 浮条、辅助功能控制和 Finder Apple Events，复用现有原生技术栈。

| 模块 | 实现方式 |
|---|---|
| Finder 目录追踪 | 监听 Finder 的活动窗口及目录相关变化，通过脚本接口读取窗口 `target`，缓存最后有效目录。以事件触发读取，避免后台持续轮询。 |
| 文件面板识别 | 使用 `AXObserver` 和 `AXUIElement` 检查前台焦点、窗口及文件浏览控件结构，识别标准文件面板。 |
| 目录浮条 | 使用不激活 青蛙导航 的 `NSPanel`，根据目标窗口几何信息定位，点击时保持文件选择窗口的操作上下文。 |
| 目录导航 | 确认目标面板，发送 `⌘⇧G` 打开“前往文件夹”，通过辅助功能填写路径，确认该子面板，再回读导航结果。 |
| 条件快捷键 | 使用 `CGEventTap`，仅在存在有效目标目录且已识别的文件面板可操作时消费 `Control + G`，其余场景原样放行。 |

### 跨应用边界

- `NSSavePanel.directoryURL` 和 `accessoryView` 供创建面板的应用使用，不能据此直接修改其他应用的目录或插入按钮。目录入口采用视觉上贴附的独立浮条。
- Apple 文档明确，macOS 10.15 起标准打开／保存面板由独立进程绘制。识别时从系统辅助功能焦点解析真实元素及归属，兼顾宿主与面板关联；不能只查看前台应用 PID，也不固定依赖内部进程名称。
- `AXDialog` 或 `AXSheet` 角色本身不足以证明是文件选择窗口，必须结合实际文件浏览控件结构识别。
- 辅助功能树的桥接方式、可用属性和通知需要实机验证；未可靠识别的窗口不展示入口，也不拦截快捷键。
- 青蛙导航 自身前台时仅保留 Finder 目录追踪，跳过自身窗口扫描；同进程 AX 读取会直接进入 SwiftUI，后台遍历可能阻塞主线程。

### 导航可靠性

- 每一步都验证目标窗口、会话和焦点；窗口变化、控件不可写或超时就中止。
- 只有确认“前往文件夹”的输入控件及所属子面板后才填写并提交路径，避免 Return 落到外层“打开／保存”按钮。
- 路径通过辅助功能控件写入，不占用系统剪贴板。
- 以文件面板实际目录的回读结果确认导航完成，不把成功发送按键当作成功切换目录。
- 快捷键回调只做轻量判断与事件分发，辅助功能调用、Apple Events 和目录检查放在回调之外。
- 与现有启动台快捷键冲突时，保留点击入口并提示调整快捷键；没有有效目录时仍遵循完全隐藏入口的规则。

## 3. 青蛙导航 接入与权限

### 应用集成

- 在 `macos/Sources/Frog/Application.swift` 的应用入口中管理生命周期。
- 目录追踪、面板识别、导航、浮条和快捷键各自封装，外部系统访问可替换，便于测试和兼容性调整。
- 设置开关及权限状态遵循前述“设置开关”交互约定。
- 开关仅保存到本机 UserDefaults，目录缓存仅保存在内存中。
- `--data-directory` 隔离运行延续现有不写本机偏好的规则。
- 功能关闭、权限撤回或应用退出时清理观察者、浮条和快捷键监听。

### 权限与打包

- 需要“辅助功能”权限，用于识别和操作其他应用的文件选择窗口。
- 需要“自动化 → Finder”授权，用于读取 Finder 窗口目录。
- 键盘监听与事件发送根据 `CGPreflightListenEventAccess()`、`CGPreflightPostEventAccess()` 及实际监听创建结果检查，按系统需要引导授权，不预先保证固定的授权数量。
- 补充 `NSAppleEventsUsageDescription` 和当前 Hardened Runtime 所需的 `com.apple.security.automation.apple-events` entitlement。
- 窗口定位使用辅助功能元数据，无需为截图引入屏幕录制权限。
- 使用实际安装的 Release 应用验证授权、权限撤回和更新后的权限状态。

## 4. 实施步骤与验收

### 第一步：验证跨应用链路

- 在当前 macOS 26.0.1 上，以一个原生应用、Safari／Chrome 和一个 Electron 应用调用的标准面板验证方案。
- 覆盖打开、保存和选择文件夹三类窗口，记录实际辅助功能树、面板归属及通知行为。
- 验证 Finder 多窗口、标签页目录读取和最后有效目录缓存。
- 验证“前往文件夹”完整导航链路和目录回读，确认不会提交外层面板。

### 第二步：接入完整交互

- 完成跟随浮条、条件快捷键、设置开关、权限引导与后台生命周期。
- 处理 青蛙导航 已隐藏、窗口移动／缩放、多显示器和其他应用全屏场景。
- 处理没有有效目录、目录失效、面板关闭、应用切换和权限撤回，及时撤下入口并释放快捷键。

### 第三步：回归与交付检查

- 为目录缓存、面板识别规则、窗口定位和导航取消逻辑编写有意义的自动化测试，运行 `swift test`。
- 验证设置开关默认关闭、开启后按权限状态生效、关闭后立即停止功能，以及重启后的状态恢复和隔离运行不持久化。
- 验证三类文件面板均能导航；保存文件名保持正确，最终打开、保存或选择仍需用户确认。
- 验证无有效目录时没有入口、没有提示文案，`Control + G` 原样放行；有效目录恢复后入口和快捷键恢复。
- 覆盖 Finder 多窗口／标签页、关闭窗口、虚拟位置、中文及空格路径、目录被删除、外置盘断开。
- 覆盖焦点快速切换、连续按键、权限拒绝／撤回，以及普通编辑窗口中的 `Control + G` 不受影响。
- 使用 Release 应用实测后台开销、浮条首击、焦点保持、隐藏／恢复、多屏及全屏行为，并记录实际支持的系统和应用。

## 5. 可行性结论与依据

基础公共 API 能力已通过代码、SDK 和官方文档核实；跨应用完整链路尚未实测。首版以标准面板为支持目标，具体兼容性以实测记录为准，主要实现成本在跨应用和系统版本差异。

Default Folder X 已提供同类体验，可作为现成替代。青蛙导航 自行集成采用只保留目录快跳核心交互的方案。

参考资料：

- [Apple NSOpenPanel](https://developer.apple.com/documentation/appkit/nsopenpanel)：标准打开面板及独立进程说明。
- [Apple NSSavePanel](https://developer.apple.com/documentation/appkit/nssavepanel)：标准保存面板及独立进程说明。
- [Apple Monitoring Events](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html)：全局事件 monitor 只能观察，不能阻止按键派发，不能代替条件拦截。
- [Apple NSAppleEventsUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription)：自动化授权用途说明。
- [Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events)：Hardened Runtime 下的 Apple Events 能力配置。
- 本机 `/System/Library/CoreServices/Finder.app/Contents/Resources/Finder.sdef`：Finder 窗口 `target`、窗口顺序和选中项目的脚本接口定义。
- [Default Folder X](https://www.stclairsoft.com/DefaultFolderX/)：同类文件面板增强功能参考。
