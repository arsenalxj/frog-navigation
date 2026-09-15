# Windows 当前验证

内部身份已统一为 Frog。旧身份的原始验收记录归档到项目同级 `frog-navigation-history/20260915-051305/`，不作为本次身份变更的验证结果。

2026-09-15 检查结果：

- CMake 源文件路径、资源和安装打包路径一致；PowerShell 文件保持 UTF-8 BOM。
- 当前 `frog-bookmarks` fixture 已通过 macOS FrogCore 解码与往返测试。
- Windows x64 Release 已在 MSVC 19.51 / Visual Studio 2026 环境构建成功。
- CTest 全部通过：`core`、`image-cache`、`native-smoke`，共 3 项；原生运行测试使用隔离数据目录。
- ZIP 解包与 Release 可执行文件一致性、ASCII 文件名、隔离首次安装、更新、旧版中文可执行名升级、未知目录保护、卸载及隔离数据保留检查全部通过；报告位于 `build/verification/package-report.json`。
- 本次图标修复已完成真实数据副本与 1,000 书签的性能采样，结果见下文；完整人工交互验收及本次版本的正式安装尚未执行。

在 Windows 项目根目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File windows/scripts/build.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File windows/scripts/verify-package.ps1
```

以上结果来自本次 Windows 构建及隔离检查，不继承旧身份的验证结论。

## Windows 交付命名

可执行文件为 `Frog.exe`，ZIP 为 `Frog-windows-x64.zip`，解压根目录为 `Frog/`。CMake、版本资源、构建／安装／卸载／性能脚本、文档已同步；安装包验证同时检查 ZIP 文件名和全部条目名仅含 ASCII。安装脚本继续识别旧版中文可执行名以完成升级，交付内容使用英文名。

本次已在 Windows 环境重新构建，并通过安装包验证。

## SVG 图标与网站直连

2026-09-15 增加 Direct2D SVG 解码，并移除 Google S2 图标兜底。已补充路径渲染、透明度、viewBox 居中裁剪、PNG 往返、无效尺寸与离线缓存测试；网络验收程序加入 DeepSeek 平台链接并强制刷新。

远端开发时已核对 Microsoft SDK 的 SVG API 声明、链接依赖及源码差异。合入后已在 Windows/MSVC 环境重新构建 x64 Release，CTest 的 `core`（含新增 SVG 测试）与 `native-smoke` 全部通过。上述 ZIP 与隔离安装验证完成于合入 SVG 更新之前，当时合并验证使用 `-SkipPackage`；本次图标缓存修复已重新生成包含这些功能的 ZIP。下列三个网站的强制下载专项检查尚未单独执行，可运行：

```powershell
.\windows\build\Release\FrogIconProbe.exe windows/build/verification/network
```

检查生成的 `network-report.json` 中三个网站均加载成功，并查看隔离缓存中的 DeepSeek PNG 是否正确显示鲸鱼轮廓及透明背景。

## 缓存加载与收起后复用

2026-09-15：新增 1 个专用缓存线程，保留 2 个慢任务线程；正常收起保留有效 Direct2D 表面、图标和壁纸，图标位图最多 128 张并按最近使用情况淘汰。详见 [图标缓存方案](../plans/PLAN_WINDOWS_ICON_CACHE.md)。

自动化验证：

- `image-cache` 在本机 HTTP 服务确认两个网络请求等待响应之后提交缓存请求，验证缓存能在网络响应释放前完成；同时覆盖暂停与重开、重复请求、尺寸升级、旧下载丢弃、损坏缓存恢复、刷新失败保留旧缓存、队列上限及可重试结果。
- `native-smoke` 使用 181 个书签及预置 PNG，确认连续重开首帧使用真实位图、绘制表面不重建、已有位图不重复读盘；遍历所有页面触发 128 张上限，再返回首页验证被淘汰图标重新加载。
- 用带合法 RECT 的 `WM_DPICHANGED` 消息触发重建，确认图标恢复和绘制表面代次增加；原有中文表单、草稿、冲突、拖拽、主题及退出检查全部通过。该消息测试不代替真实跨显示器 DPI 切换或驱动重置验收。

实际数据副本对照使用 38 个书签和 27 张有效 PNG，两个版本均为独立新进程，系统文件缓存未清空。旧安装版本联网打开“工作”约 8.8 秒后才显示真实图标；旧模块重放中四张缓存排队约 12.47 秒。新版结果如下：

| 测量项 | 联网 | 离线 |
| --- | ---: | ---: |
| 首页命中的 25 张缓存，请求完成最大耗时 | 12.86 ms | 12.20 ms |
| 新进程首次可操作绘制（从请求展开计时） | 90.99 ms | 88.82 ms |
| 首帧真实图标 / 绘制图标 | 25 / 30 | 25 / 30 |
| “工作”连续三次再次展开 | 14.92～15.35 ms | 12.96～20.34 ms |
| “工作”重开首帧真实图标 / 绘制图标 | 4 / 4 | 4 / 4 |

剩余五张首页缩略图没有有效缓存。已有缓存的图标均在新进程首次可操作绘制时显示；“工作”重开使用原有绘制表面和位图，没有重复读盘。已查看首页、文件夹及重开截图；首帧结论来自成功绘制后记录的诊断计数，不以动画结束后的截图推断。

真实数据副本联网收起 30 秒后：私有提交 **33.53 MB（31.97 MiB）**，工作集 **62.54 MB**；D3DKMT 查询的已提交专用显存 **18.11 MiB**、共享显存 **2.82 MiB**，随后 10 秒平均 CPU **0%**（单核 100% 口径）。这些是整个进程的值，不是新增线程或图标的净增量，也不能将提交显存当作当前物理驻留显存。

`measure-performance.ps1` 生成 1,000 个隔离书签：进程启动至可操作 **176.98 ms**，三次重开 **23.32 / 29.19 / 20.25 ms**，收起 30 秒私有提交 **33.92 MB**，10 秒平均 CPU **0%**。启动 ≤1,000 ms、重开 ≤150 ms、私有提交 ≤50 MB、平均 CPU ≤0.5% 四项目标均达到；该场景离线且未预置图标。常规 GPU 性能计数器不可用，显存数据取上面的真实数据副本 D3DKMT 采样。

环境：Windows 11 10.0.26100、i7-13700HX、32 GiB 内存、AMD Radeon HD 7670，1920×1080 / 100% 缩放。首次启动仍异步读取缓存，不保证其他机器每次冷启动零占位；真实高 DPI、多显示器及驱动失效后的行为和资源成本仍需跨设备验证。

本地证据（均为忽略的验收产物）：

- `build/verification/icon-delay-20260915/fix-report.md`、`runs/ui-fixed-online/`、`runs/ui-fixed-offline/`：请求时间、首帧、截图与内存。
- `build/Testing/artifacts/application.jsonl`：181 书签、位图上限与重建记录。
- `build/performance/20260915-175337/report.json`：1,000 书签性能与硬件信息。

本次 Release 已重新构建并打包；正式书签、偏好、27 张缓存和已安装 EXE 的哈希与检查前一致，正式安装进程仍运行旧版本。本次交付尚未安装。
