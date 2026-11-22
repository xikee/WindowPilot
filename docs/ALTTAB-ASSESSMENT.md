# AltTab 评估与瞬切改进记录

评估日期：2026-11-19。对照对象为用户提供的 `AltTab.app` 11.10.2 与瞬切 Preview 3 / 构建 6。结论：继续改进当前瞬切，优先完善系统服务层。此次本地改进产物标记为构建 7，没有发布新版 Release。

## 为什么选择继续改进瞬切

当前瞬切已经具备窗口目录、MRU 选择、快速松键、当前应用范围、搜索、最小化/隐藏恢复、窗口预览、设置与权限引导，以及可运行的核心和界面检查。重新独立复刻 AltTab 会重新实现这些已存在的链路，也不会自动解决 macOS 窗口身份、辅助功能响应和截图兼容问题。

| 路线 | 可获得的结果 | 主要成本与约束 | 本次判断 |
| --- | --- | --- | --- |
| 从零独立复刻完整 AltTab | 按原产品重新设计功能和交互 | 重做已有状态机与产品基础；完整跨 Space 覆盖仍需解决系统 API 限制；需要重新建立测试基线 | 当前投入收益较低 |
| 基于 AltTab 源码分叉 | 更快接近 AltTab 完整功能集合 | 需核对对应版本全部许可、资源与分发要求；承担私有接口、更新器和其他上游模块的维护 | 只有明确要求完整 AltTab 功能集合时才值得重新评估 |
| 渐进重构当前瞬切 | 保留轻量中文原生体验，逐步改善可靠性 | 仍须进行多系统、窗口、显示器与权限实测 | 本次执行路线 |

没有足够数据给出准确工期或声称某方案快若干倍。原仓库性能记录来自单机少量命中缓存的样本，也不能作为本次性能提升的证明。

## craft-anything 的实际使用

学习来源为 [官方仓库](https://github.com/storytold/craft-anything) 与 v0.6.1 CLI 源码。它同时提供 CLI 和 MCP；本次使用官方 CLI 的静态分析工具，没有调用 AI chat/rebuild，没有启动自动生成项目的流程。

- CLI：官方发行版 `craft-anything-cli 0.6.1`，macOS Universal。
- ZIP SHA-256：`ddbae05f52a5526e149f656b0b44cf73a60ad9ec0a33d718f330bf231b988c2f`，与 GitHub Releases 的资产摘要一致。
- `codesign --verify --strict` 校验通过，签名为 Learning Machines LLC，Team ID `DJ6XS33FX8`。
- 工具解压到独立临时目录后使用，没有全局安装、修改 PATH 或注册 MCP。
- 采用 `--deep` 读取本地文件；这些检查不需要将 AltTab 二进制上传给模型。

实际运行的工具：

| CLI 命令 | 用途 | 结果与边界 |
| --- | --- | --- |
| `apple-app-graph-build --path …` | 枚举应用包、框架和资源结构 | 识别主程序、Sparkle 与 CrashReporter；属于文件结构投影，不代表完整业务架构 |
| `apple-macho-show --path … --architecture arm64 --limit 5000` | 检查 Mach-O 导入、链接库与构建信息 | 读取 1,573 个导入记录；确认 SkyLight 和 CGS/SLS 符号；没有运行目标程序 |
| `apple-dylibs-resolve --path … --architecture arm64` | 静态解析包内动态库依赖 | 检查 5 个镜像，未报告依赖解析 findings；系统共享缓存与运行时 dlopen 不在其证明范围 |
| `apple-swift-types-list …/Contents/MacOS/AltTab` | 从符号推断 Swift 类型 | 目标已剥离符号，主要得到系统框架类型，不能据此恢复 AltTab 完整源码结构 |

原始 JSON 与证据目录保存在本地 `.build/craft-analysis/`，由 `.gitignore` 排除；它们不是应用运行依赖。

关键证据编号：

- 应用图：`ev_eb20891fdf49afcb46d78e3f552f17274f28f5549126e13f6852d29b85151463`
- arm64 Mach-O：`ev_5929f149d45cea961464f8d8fe8f43926659624529e817061ef0af8a6bf626c4`
- 动态库：`ev_f34e4c544b6eb3eb20b3d7f62baa5728e3701624a9f728d4b785895e729fcc6a`
- Swift 类型：`ev_2dec142ff171d2a6aca12af63503bfc2a0ea24b3ea150949f75f73d434c4931a`
- AltTab 主程序 SHA-256：`8e20a2ead633334fb155bdbb9078c5a0fd14165f463bdf3ed46d64f521ee4022`

craft-anything 仍处于 alpha。其静态分析结果有价值，但不提供可靠性或端到端行为的自动证明，本次没有使用所谓相似度评分做决策。

## AltTab 中值得借鉴的工程事实

本地 Info.plist 与 Mach-O 一致显示 AltTab 11.10.2，最低 macOS 12，含 arm64/x86_64 两种架构。本地 `codesign -dv` 显示 Developer ID 签名与附带公证票据；这次没有另做在线 Gatekeeper 公证验证。包内有 Sparkle 自动更新与 CrashReporter，和瞬切当前的无第三方依赖、无网络请求定位不同。

二进制链接 `/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight`，导入包括：

- `CGSCopyManagedDisplaySpaces`、`CGSCopySpacesForWindows`、`CGSManagedDisplayGetCurrentSpace`：Space 信息。
- `SLSWindowQueryWindows`、`SLSWindowQueryResultCopyWindows` 与 WindowIterator 系列：窗口服务器批量查询。
- `CGSHWCaptureWindowList`：私有截图路径。
- `_AXUIElementGetWindow`：AX 与窗口服务器身份关联。

对照 [v11.10.2 的 Spaces.swift](https://github.com/lwouis/alt-tab-macos/blob/v11.10.2/src/switcher/state/Spaces.swift)、[WindowServerQuery.swift](https://github.com/lwouis/alt-tab-macos/blob/v11.10.2/src/windowserver/WindowServerQuery.swift) 和 [WindowThumbnails.swift](https://github.com/lwouis/alt-tab-macos/blob/v11.10.2/src/switcher/state/WindowThumbnails.swift)，可以核实其后台查询、截图限流及按系统版本选择截图实现的思路。

这些事实说明 AltTab 的覆盖能力不只来自界面；完整复刻会涉及更大的系统兼容范围。本次保留瞬切的公开 API 路线，没有复制上述源码、二进制、图标或其他资源。AltTab 本地包声明 GPL-3.0，GitHub 仓库元数据也标为 GPL-3.0；若未来选择源码分叉，应先核对对应版本的完整许可与第三方资源许可。

## 本次实现

### 窗口目录与匹配

- 提取纯 `WindowMatcher`：标题不能绕过几何约束；多个候选或多个 AX 窗口争用同一个 CG 编号时不关联截图，保留通过 AX 切换的能力。
- 增加基于单调时钟的 `CatalogFreshness`。单个窗口最后一次成功读取超过 6 秒后不继续作为可用条目；查询超时不刷新其有效期。
- 每轮目录查询设 750ms 协作预算，每个应用设 250ms 预算，单次 AX 查询最多申请 60ms 超时；在应用间及应用内部窗口间轮转，避免每轮总从同一批条目开始。
- 窗口的销毁、标题、位置、大小和最小化事件触发合并刷新；仍保留每 2 秒轮询作为不支持通知应用的补偿。它仍是有预算的快照扫描，没有宣称已完成全部增量目录架构。
- 观察者创建或关键通知注册完全失败后允许重试，不再永久把 PID 标成已监听。
- 通过请求标识和生命周期隔离目录回调；诊断新增扫描时长、预算是否耗尽和目录年龄，不记录标题或截图内容。

预算只能在系统调用之间检查；macOS 内部原生调用若不遵守超时，无法从当前进程强制中断。因此不能把 750ms 当作扫描完成的硬实时保证。

### 激活事务

- 提取可替换的 `WindowActivationBackend` 与 `WindowActivator`。
- `AXRaise` 成功后，继续确认前台 PID 和实际 focused AX window；只有匹配目标才报告 `confirmed`。
- 确认最多等待 1.2 秒。超时、系统拒绝、窗口不可用、新请求取代旧请求分别返回原因。
- 新激活、重新打开切换器和服务停止会使旧请求失效；尚未执行的后台动作检查取消标识，迟到结果不会再报告成功。
- 已经进入系统内部的 AX 动作无法撤回。确认阶段只读取焦点，不重复抢占前台。

### 缩略图

- 将截图后端、时间与容量参数分离，允许在无屏幕录制权限时确定性验证异步控制流。
- 前置 `SCShareableContent` 枚举和单张截图各有 1 秒逻辑超时。
- 枚举和截图共用一个跨会话原生操作槽；逻辑超时不释放仍在运行的原生调用，避免请求持续堆积。
- 内存缓存限制为 48 张、约 32 MiB 像素数据；只淘汰离屏图像，可见图像占满预算时降级为图标。离屏图像被淘汰后，滚回对应窗口时允许重新截图；失败或超时条目仍避免在同一会话反复重试。
- 保留选择优先、可见项请求、批量发布和每次关闭清空图片的行为。

32 MiB 指像素数据估算，不含系统框架、对象和截图临时工作区的全部内存。原生截图若永不返回，后续请求持续降级为图标，直到真实调用返回或应用重启。

## 验证范围与后续边界

实际验证结果记录在 [VALIDATION.md](VALIDATION.md)：16 个核心/匹配/有效期场景、6 个激活事务场景、10 组缩略图测试和 24 项真实 AppKit 界面/本地事件检查通过，构建与临时签名完整性校验通过。对本轮较早一次构建 7 运行 `apple-macho-show`，读取全部 742 个导入记录，没有发现 CGS/SLS 窗口接口、`_AXUIElementGetWindow` 或 PrivateFrameworks 链接；证据为 `ev_6710cbfe89a4ce595a0baa45de5f649eb8da496ef184adc318fa78680355d240`。这一证据对应缩略图滚回重拍补修前的产物。补修后再次调用下载的 CLI 被自动审批以“外部代码”为由拒绝，因此最终产物改用系统自带的 `otool` 和 `nm` 复核链接依赖与导入符号。

最终源码已重新通过上述全部测试、构建与界面检查；系统工具检查最终可执行文件的 742 个导入符号，未发现指定私有窗口符号或私有框架链接。最终检查结果与 SHA-256 保存在 `.build/craft-analysis/windowpilot-build7-final-system-check.json`。

本次没有重新授予系统权限或复测真实跨应用激活与屏幕截图；不根据代码结构推断真实跨应用性能，也不将模拟后端测试称为桌面端到端验证。

完整跨 Space/全屏支持、中文输入法组合输入、Universal 分发、Developer ID 签名与公证、自动更新均未纳入本次实现。窗口逻辑身份仍基于 AX 引用，尚未引入完整的跨进程窗口身份服务。不同 macOS 版本、复杂 AX 应用、多显示器和长时间运行仍需专项实测。
