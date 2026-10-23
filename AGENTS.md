# AGENTS.md

This file provides guidance to agents when working with code in this repository.

---

# 第一部分：通用智能体行为准则

用于减少大语言模型常见编码错误的行为准则。根据需要与项目特定说明结合使用。  
**权衡：** 这些准则更偏重谨慎而非速度。对于简单任务，请自行判断。

## 1. 编码前先思考
**不要想当然。不要掩盖困惑。明确说明取舍。**  
实施前：
- 明确说明你的假设。如果不确定，请先询问。
- 如果存在多种理解，请全部说明，不要自行默默选择。
- 如果存在更简单的方案，请明确指出。必要时提出异议。
- 如果有不清楚之处，请停下来，指出困惑所在并询问。

## 2. 简单优先
**用最少的代码解决问题。不做推测性设计。**
- 不添加要求之外的功能。
- 不为只使用一次的代码创建抽象。
- 不增加未被要求的“灵活性”或“可配置性”。
- 不为不可能发生的场景添加错误处理。
- 如果写了 200 行代码，而 50 行就能解决，请重写。  
问问自己：“资深工程师会不会认为这过于复杂？”如果会，请简化。

## 3. 精准改动
**只改必须改的内容。只清理自己产生的问题。**  
编辑现有代码时：
- 不要顺手“改进”相邻代码、注释或格式。
- 不要重构没有问题的代码。
- 遵循现有风格，即使你会采用不同的写法。
- 如果发现无关的无效代码，请指出，但不要删除。  
当你的改动产生遗留内容时：
- 删除因你的改动而不再使用的导入、变量和函数。
- 除非明确要求，否则不要删除原本就存在的无效代码。  
判断标准：每一处改动都应能直接追溯到用户的要求。

## 4. 目标驱动执行
**定义成功标准。循环执行，直到验证通过。**  
将任务转化为可验证的目标：
- “添加校验” → “为无效输入编写测试，然后让测试通过”
- “修复缺陷” → “编写能够复现缺陷的测试，然后让测试通过”
- “重构 X” → “确保重构前后测试均能通过”  
对于多步骤任务，给出简短计划：
```
1. [步骤] → 验证：[检查方式]
2. [步骤] → 验证：[检查方式]
3. [步骤] → 验证：[检查方式]
```
明确的成功标准能让你独立循环执行。模糊的标准（如“让它能用”）则需要不断澄清。

---
**这些准则有效的表现：** 差异中不必要的改动更少，因过度复杂而返工的情况更少，并且澄清问题发生在实施之前，而不是出错之后。

## 5. 完成标准
交付前确认：
- 实现满足当前需求，没有附带无关功能或重构。
- 目录归属、扩展权限与持久化数据兼容性未被意外破坏。
- 相关测试与检查已经通过，或未验证项已明确说明。
- 差异中没有生成产物、调试代码、临时文件或敏感信息。
- 最终说明简要列出改动内容、验证结果和必要的后续操作。

## 6. 重要约定
- **Git 提交**
  - 仅在用户明确要求时创建提交。
  - 格式：使用 `<type>: <中文描述>`。
  - 允许的类型：`feat`、`fix`、`refactor`、`chore`、`docs`、`test`、`perf`、`build`、`ci`、`style`、`revert`。
  - 每个提交应只包含一项独立且完整的变更。
  - 提交说明和 PR 描述中不要添加 `Co-Authored-By` 等 AI 署名行或生成工具的署名。
- **代码注释**
  - 改动代码时，代码注释要和附近的代码（或者同类代码）的语言、语气与密度保持一致。

---

# 第二部分：OI 项目架构与开发指南

## 1. 项目重要约定

- **程序界面运行与测试协作**
  - 重要！！：本项目不需要进行测试，你修改完成后我会拉取到本地使用xcode来进行测试。你只需要把所有文件写好即可。
  - 当需要进行程序界面（GUI）交互测试时，智能体应先告知用户在 Xcode 中将程序运行起来；用户运行起来后，由智能体来进行相关的界面与功能测试。

## 2. 常用构建与测试命令

- **构建项目 (Debug)**:
  `xcodebuild -project OI.xcodeproj -scheme OI -configuration Debug build`
- **运行全部单元测试**:
  `xcodebuild -project OI.xcodeproj -scheme OI -configuration Debug test -destination 'platform=macOS'`
- **运行单个测试用例**:
  `xcodebuild -project OI.xcodeproj -scheme OI -configuration Debug test -destination 'platform=macOS' -only-testing:OITests/ApplicationSearchTests/testPinyinPrefixMatch`
- **运行指定测试套件**:
  `xcodebuild -project OI.xcodeproj -scheme OI -configuration Debug test -destination 'platform=macOS' -only-testing:OITests/LauncherViewModelTests`
- **测试运行策略**:
  - 平时迭代：只运行被改动的测试类（`-only-testing:OITests/<类名>`），避免每次全套运行导致测试宿主界面弹框。
  - 交付/提交前：运行一次全部单元测试确认没有回归，并在最终说明中报告结果。
- **发布**：先编写 `docs/releases/v<版本号>.md`，再在干净的工作区执行 `scripts/release.sh`，按其打印的 `gh release create` 命令发布。

项目 target 为 `OI`，测试 target 为 `OITests`。最低部署版本为 macOS 27.0，使用 Swift 6 语言模式。Debug、Release 和 Tests 均已开启完整严格并发检查（Complete Strict Concurrency Checking），并发问题按编译错误处理。

工程使用显式文件引用（不是自动同步的文件夹）：新增 Swift 文件必须在 [OI.xcodeproj/project.pbxproj](OI.xcodeproj/project.pbxproj) 中加入 `PBXBuildFile`、`PBXFileReference`、所属目录的 `PBXGroup` 与对应 target 的 Sources 构建阶段，否则不会参与编译。

## 3. 架构定位与分层设计

本项目是一个原生 macOS 菜单栏工具（`LSUIElement: true`，Accessory 模式常驻系统菜单栏，无 Dock 图标），包含两大功能：
- **启动器**：全局快捷键 `⌥Space` 呼出，搜索应用与文件，快速查询（计算、本机 IP），网址与路径直达，`⌘↩` 网页搜索，`Tab` 切到 Quick AI 问答；
- **划词翻译**：触控板用力点按翻译单词，`⌥D` 翻译选中文字或剪贴板，`⌥S` 截图翻译，译文在原文旁的气泡中流式显示。

采用**单 App Target + 明确分层 + Composition Root**的整洁架构模式。

### 依赖方向规范

```text
App -> Features -> Application -> Domain
App -> Infrastructure -> Application / Domain
App -> UI -> Features / Application / Domain
```

### 核心层次职责

- [App/](App/)：Composition Root（依赖组装根）。
  - [App/OIApp.swift](App/OIApp.swift) 是 SwiftUI 入口，只保留一个空的 Settings 场景，并把应用菜单的「设置…」指向自有的设置窗口；[App/AppDelegate.swift](App/AppDelegate.swift) 创建并启动协调者。
  - [App/AppConfiguration.swift](App/AppConfiguration.swift)：随分发方式或测试环境变化的配置（应用扫描目录、内置应用别名、文件结果条数与最短查询长度、检查更新的 GitHub 仓库）。
  - [App/AppDependencies.swift](App/AppDependencies.swift) 中的 `AppDependencies.live(configuration:)` 是项目中**唯一**实例化具体基础设施适配器的入口。划词翻译与检查更新的依赖分别打包为 `TranslatorDependencies`、`UpdateDependencies`，测试注入依赖图时可省略。
  - [App/AppCoordinator.swift](App/AppCoordinator.swift) 协调应用生命周期、菜单栏、三个全局快捷键（呼出、翻译、截图翻译）、设置窗口与检查更新。
  - Feature 绝不直接创建具体基础设施。
- [Domain/](Domain/)：业务核心实体（[Domain/Models/](Domain/Models/)）：`AppDescriptor`（应用）、`FileDescriptor`（文件与文件夹）、`SearchResult`（启动器的一行结果：应用、文件、快速查询或网址）、`QuickQueryResult`、`TranslationLanguage`、`WebSearchEngine`、`AppVersion`。严格限制为 Foundation-only 并符合 `Sendable` 协议，严禁引入 AppKit、SwiftUI、Carbon 等平台或表现层依赖。
- [Application/](Application/)：业务流程契约与纯业务逻辑。
  - [Application/Ports/](Application/Ports/)：定义外部依赖协议契约，每个端口一个文件：
    - 启动器：`AppCatalog`、`ApplicationLaunching`、`AppUsageStoring`、`FileSearching`、`FileOpening`（打开、在 Finder 中显示、在终端打开、用其他 App 打开、按路径取条目）、`URLOpening`、`GlobalShortcutHandling`；
    - Quick AI 与划词翻译：`QuickAIAnswering`、`QuickAIKeyStoring`、`TextCapturing`、`WordSelecting`、`ForceTouchMonitoring`、`LanguageDetecting`、`ScreenTextRecognizing`、`TextSpeaking`、`TranslatorEnvironmentHandling`（辅助功能与屏幕录制权限）；
    - 通用：`AppSettingsStoring`（`AppSettings` 设置模型也定义在这里）、`LoginItemControlling`、`UserNotifying`、`LatestReleaseFetching`。
    - 部分端口文件同时提供内存实现（`MemoryAppUsageStore`、`MemoryAppSettingsStore`、`MemoryQuickAIKeyStore`、`MemoryUserNotifier`、`MemoryTranslatorEnvironment`），用作默认值与测试替身。
  - [Application/UseCases/](Application/UseCases/)：用例流程：`DiscoverApplications`、`LaunchApplication`、`SearchFiles`（含文件结果的二次排序 `FileResultRanker`）、`OpenFile`、`OpenURL`、`AskQuickAI`、`TranslateText`、`CheckForUpdates`；[Application/UseCases/QuickAIStreaming.swift](Application/UseCases/QuickAIStreaming.swift) 是 Quick AI 与翻译共用的流式请求（两者的接口地址、模型与 API Key 各自填写）。
  - [Application/Search/](Application/Search/)：自建纯内存搜索引擎，包含分级匹配索引（[Application/Search/ApplicationSearchIndex.swift](Application/Search/ApplicationSearchIndex.swift)）、搜索文档模型（[Application/Search/ApplicationSearchDocument.swift](Application/Search/ApplicationSearchDocument.swift)）与文本分词/拼音/首字母归一化处理（`SearchTextNormalizer`）。
  - [Application/Errors/](Application/Errors/)：稳定的跨层错误模型（[Application/Errors/ApplicationError.swift](Application/Errors/ApplicationError.swift)），屏蔽平台底层异常细节。
- [Infrastructure/](Infrastructure/)：系统能力具体实现。
  - [Infrastructure/AppCatalog/](Infrastructure/AppCatalog/)：文件系统应用遍历（[Infrastructure/AppCatalog/FileSystemAppCatalog.swift](Infrastructure/AppCatalog/FileSystemAppCatalog.swift)）与应用目录变动监听（[Infrastructure/AppCatalog/AppDirectoryWatcher.swift](Infrastructure/AppCatalog/AppDirectoryWatcher.swift)）。
  - [Infrastructure/FileSearch/](Infrastructure/FileSearch/)：基于系统 Spotlight 索引（`MDQuery`）的文件搜索（[Infrastructure/FileSearch/SpotlightFileSearcher.swift](Infrastructure/FileSearch/SpotlightFileSearcher.swift)）。
  - [Infrastructure/Launch/](Infrastructure/Launch/)：基于 `NSWorkspace` 的应用启动、文件与网址打开（`WorkspaceApplicationLauncher`、`WorkspaceFileOpener`、`WorkspaceURLOpener`）。
  - [Infrastructure/QuickAI/](Infrastructure/QuickAI/)：OpenAI 兼容接口的流式客户端（`OpenAICompatibleQuickAIClient`）与钥匙串中的 API Key 存储（`KeychainQuickAIKeyStore`，Quick AI 与翻译各存一份）。
  - [Infrastructure/Translator/](Infrastructure/Translator/)：辅助功能取词（`AccessibilityTextCapturer`）、取不到时模拟双击选词（`DoubleClickWordSelector`）、触控板用力点按监听（`GlobalForceTouchMonitor`）、语种识别（`NaturalLanguageDetector`）、截图识字（`VisionScreenTextRecognizer`，ScreenCaptureKit + Vision）、发音朗读（`SystemTextSpeaker`，`AVSpeechSynthesizer`）、权限状态与授权流程（`SystemTranslatorEnvironment`）。
  - [Infrastructure/Shortcut/](Infrastructure/Shortcut/)：基于 Carbon API 的全局热键注册，每个快捷键一个实例，按热键 ID 区分。
  - [Infrastructure/Settings/](Infrastructure/Settings/)：基于 `UserDefaults` 的设置存储。
  - [Infrastructure/Usage/](Infrastructure/Usage/)：基于 `UserDefaults` 的应用使用历史持久化存储。
  - [Infrastructure/LoginItem/](Infrastructure/LoginItem/)：基于 `SMAppService` 的开机自启。
  - [Infrastructure/Notifications/](Infrastructure/Notifications/)：基于 `UNUserNotificationCenter` 的系统通知（后台打开失败等提示）。
  - [Infrastructure/Update/](Infrastructure/Update/)：经 GitHub Releases API 查询最新版本。
  - *约束：Infrastructure 不得依赖 Features 或 UI 层。*
- [UI/](UI/)：AppKit 与 SwiftUI 桥接及窗口管理。
  - [UI/Panel/](UI/Panel/)：Spotlight 风格的启动器浮动面板。[UI/Panel/LauncherPanelController.swift](UI/Panel/LauncherPanelController.swift) 管理面板显示、按键与结果操作；另有玻璃表面（`LauncherPanelSurface`）、高度缩放动效（[UI/Panel/PanelAnimationCoordinator.swift](UI/Panel/PanelAnimationCoordinator.swift)）、SwiftUI 主视图（`LauncherView`）、AppKit 输入框与结果列表（`LauncherSearchInput`、`LauncherResultsList`）、`⌘K` 操作卡片（`LauncherActionSheetView`）与 `⌘Y` Quick Look（`QuickLookPresenter`）。
  - [UI/Translator/](UI/Translator/)：[UI/Translator/TranslatorPanelController.swift](UI/Translator/TranslatorPanelController.swift) 管理翻译气泡（跟随每次翻译的当前气泡与固定在屏幕上的气泡）与气泡内的按键；`TranslatorBubble` 是单个气泡窗口及单词高亮；`ScreenSelectionOverlay` 是截图翻译的框选遮罩。
  - [UI/Settings/](UI/Settings/)：设置窗口（`SettingsWindowController` 托管 SwiftUI 的 `SettingsView`）与快捷键录制控件（`ShortcutRecorderField`）。
  - [UI/StatusBar/](UI/StatusBar/)：菜单栏状态项管理（[UI/StatusBar/StatusBarController.swift](UI/StatusBar/StatusBarController.swift)）。
  - [UI/Update/](UI/Update/)：检查更新的结果提醒框（`UpdateCheckController`）。
  - [UI/Icons/](UI/Icons/)：原生应用高清图标提取与缓存；图标是 `NSImage`，`ApplicationIconProviding` 协议也定义在本层。
  - *约束：`NSImage`、`NSPanel`、`NSStatusItem` 等 UI 专属类型仅限在此层流转。*
- [Features/](Features/)：用户功能的视图模型、状态与 SwiftUI 视图。
  - [Features/Launcher/](Features/Launcher/)：[Features/Launcher/LauncherViewModel.swift](Features/Launcher/LauncherViewModel.swift) 统一编排搜索输入、结果排列与选中、`⌘K` 菜单、Quick AI 模式与打开调度；`QuickQueryResolver`（计算、本机 IP）、`WebURLResolver`（网址识别）、`LauncherActionMenu`（`⌘K` 动作）、`LauncherLayout`（面板尺寸）、`QuickAIAnswerView`（回答区）。
  - [Features/Translator/](Features/Translator/)：`TranslatorViewModel`（每个气泡一份：取词、截图识别、流式翻译、朗读）、`TranslatorState`（会话与提示）、`TranslatorView`（气泡内容）。
  - [Features/Settings/](Features/Settings/)：`SettingsViewModel`、`SettingsCategory`（侧边栏分类与可搜索的设置项名称）、`ShortcutFormatter`（快捷键展示，只用 Carbon 的键码常量）。
  - [Features/Shared/](Features/Shared/)：Quick AI 与翻译共用的 Markdown 解析与显示（`QuickAIMarkdown`、`QuickAIMarkdownBlockView`）与流式增量合并上屏（`StreamingTextBuffer`）。
  - 使用显式状态枚举（如 [Features/Launcher/LauncherState.swift](Features/Launcher/LauncherState.swift)、[Features/Translator/TranslatorState.swift](Features/Translator/TranslatorState.swift)）管理状态，避免布尔变量交叉冲突。

## 4. 搜索与排序引擎机制

### 4.1 应用搜索

搜索索引为自建纯内存快照，检索过程完全离线且不触碰磁盘，包含严格的 **8 级匹配规则**：

1. **Tier 0（完全匹配）**：应用显示名归一化后与查询完全相同。
2. **Tier 1（前缀匹配）**：应用显示名以此查询开头。
3. **Tier 2（单词前缀）**：应用名称经空格/标点分词后，某个独立单词以此查询开头。
4. **Tier 3（二级元数据）**：应用安装包文件名或 Bundle Identifier 匹配。
5. **Tier 4（别名与首字母）**：内置别名（[App/AppConfiguration.swift](App/AppConfiguration.swift)）包含查询词，或名称拉丁/汉字拼音首字母以查询开头（如 `vsc` 匹配 Visual Studio Code，`wx` 匹配微信）。
6. **Tier 5（全拼前缀）**：汉字显示名转换为无声调拼音后，从开头或任意一个字开始的前缀匹配（如 `weixin`、`xin` 匹配微信），从开头匹配的排在前面。
7. **Tier 6（子串包含）**：应用名称中任意位置包含查询词。
8. **Tier 7（模糊跳字）**：按序字符匹配（带跳字惩罚计分）。

**排序规则（Frecency）**：
- 匹配等级（Tier）具有绝对优先权。
- 同一 Tier 内依次比较文本位置（命中位置越靠前、跳字越少越好）、距上次启动的天数（30 天封顶）与启动次数（log2 缩放）；使用信号**仅用于在同一匹配 Tier 内部打破平局**，绝不会跨 Tier 提权。
- 使用历史只在设置中开启「启动历史排序」时参与排序。

### 4.2 启动器结果排列与文件搜索

- 结果顺序：网址直达 → 路径直达 → 快速查询 → 应用 → 文件（文件分组带「文件与文件夹」标题）。
- 文件搜索走 Spotlight 索引：范围为家目录，排除 `~/Library`、隐藏路径与 `.app`；查询至少 2 个字符、120ms 防抖、最新查询胜出；`FileResultRanker` 按「去扩展名完全匹配 > 名称前缀 > 其他」排序，同级按活跃时间（打开、修改、加入目录三者最新）降序，最多 100 条。
- 以 `/` 或 `~` 开头的输入只做路径直达（按路径直接查看文件系统，不经索引），不做文件搜索。

## 5. 并发模型与测试契约

- 界面、视图模型与 AppKit 协调者统一标注 `@MainActor`。
- 应用扫描、索引生成、Spotlight 查询、辅助功能取词与截图识字等耗时任务在后台执行（Detached Task 或专用队列），并通过 `Task.checkCancellation()` 等方式支持协作式取消。
- 异步结果用递增的 generation 丢弃过期结果（文件搜索、Quick AI、翻译、截图识别、取词），新的输入或触发总是胜出。
- 系统回调可能在后台线程执行：`NSWorkspace` 等完成回调显式标为 `@Sendable`，代理回调回到主线程再处理，避免 Swift 6 下的隔离断言。
- 禁止使用全局单例替换业务依赖。单元测试中均通过构造用例协议桩（Stub）、端口文件中的内存实现（如 `MemoryAppUsageStore`）或注入自定义 `AppDependencies` 进行验证。
