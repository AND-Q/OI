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
- **代码注释**
  - 改动代码时，代码注释要和附近的代码（或者同类代码）的语言、语气与密度保持一致。

---

# 第二部分：OI 项目架构与开发指南

## 1. 项目重要约定

- **程序界面运行与测试协作**
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

项目 target 为 `OI`，测试 target 为 `OITests`。最低部署版本为 macOS 27.0。Debug、Release 和 Tests 均已开启完整严格并发检查（Complete Strict Concurrency Checking）。

## 3. 架构定位与分层设计

本项目是一个原生 macOS 菜单栏启动器（`LSUIElement: true`，Accessory 模式常驻系统菜单栏，无 Dock 图标，通过全局快捷键 `⌥Space` 呼出），采用**单 App Target + 明确分层 + Composition Root**的整洁架构模式。

### 依赖方向规范

```text
App -> Features -> Application -> Domain
App -> Infrastructure -> Application / Domain
App -> UI -> Features / Application / Domain
```

### 核心层次职责

- [App/](App/)：Composition Root（依赖组装根）。[App/AppDependencies.swift](App/AppDependencies.swift) 中的 `AppDependencies.live(configuration:)` 是项目中**唯一**实例化具体基础设施适配器的入口。[App/AppCoordinator.swift](App/AppCoordinator.swift) 协调应用生命周期、菜单栏与全局快捷键调度。Feature 绝不直接创建具体基础设施。
- [Domain/](Domain/)：业务核心实体（[Domain/Models/AppDescriptor.swift](Domain/Models/AppDescriptor.swift)）。严格限制为 Foundation-only 并符合 `Sendable` 协议，严禁引入 AppKit、SwiftUI、Carbon 等平台或表现层依赖。
- [Application/](Application/)：业务流程契约与纯业务逻辑。
  - [Application/Ports/](Application/Ports/)：定义外部依赖协议契约（`AppCatalog`、`ApplicationLaunching`、`GlobalShortcutHandling`、`AppUsageStoring`）。
  - [Application/UseCases/](Application/UseCases/)：用例流程（[Application/UseCases/DiscoverApplications.swift](Application/UseCases/DiscoverApplications.swift)、[Application/UseCases/LaunchApplication.swift](Application/UseCases/LaunchApplication.swift)）。
  - [Application/Search/](Application/Search/)：自建纯内存搜索引擎，包含分级匹配索引（[Application/Search/ApplicationSearchIndex.swift](Application/Search/ApplicationSearchIndex.swift)）、搜索文档模型（[Application/Search/ApplicationSearchDocument.swift](Application/Search/ApplicationSearchDocument.swift)）与文本分词/拼音/首字母归一化处理（`SearchTextNormalizer`）。
  - [Application/Errors/](Application/Errors/)：稳定的跨层错误模型（[Application/Errors/ApplicationError.swift](Application/Errors/ApplicationError.swift)），屏蔽平台底层异常细节。
- [Infrastructure/](Infrastructure/)：系统能力具体实现。
  - [Infrastructure/AppCatalog/](Infrastructure/AppCatalog/)：文件系统应用遍历（[Infrastructure/AppCatalog/FileSystemAppCatalog.swift](Infrastructure/AppCatalog/FileSystemAppCatalog.swift)）与应用目录变动监听（[Infrastructure/AppCatalog/AppDirectoryWatcher.swift](Infrastructure/AppCatalog/AppDirectoryWatcher.swift)）。
  - [Infrastructure/Launch/](Infrastructure/Launch/)：基于 `NSWorkspace` 的应用启动实现。
  - [Infrastructure/Shortcut/](Infrastructure/Shortcut/)：基于 Carbon API 的全局热键注册。
  - [Infrastructure/Usage/](Infrastructure/Usage/)：基于 `UserDefaults` 的应用使用历史持久化存储。
  - *约束：Infrastructure 不得依赖 Features 或 UI 层。*
- [UI/](UI/)：AppKit 与 SwiftUI 桥接及窗口管理。
  - [UI/Panel/](UI/Panel/)：Spotlight 风格浮动面板、毛玻璃背景与高度缩放动效（[UI/Panel/LauncherPanelController.swift](UI/Panel/LauncherPanelController.swift)、[UI/Panel/PanelAnimationCoordinator.swift](UI/Panel/PanelAnimationCoordinator.swift)）。
  - [UI/StatusBar/](UI/StatusBar/)：菜单栏状态项管理（[UI/StatusBar/StatusBarController.swift](UI/StatusBar/StatusBarController.swift)）。
  - [UI/Icons/](UI/Icons/)：原生应用高清图标提取与缓存。
  - *约束：`NSImage`、`NSPanel`、`NSStatusItem` 等 UI 专属类型仅限在此层流转。*
- [Features/](Features/)：用户功能与界面状态呈现（[Features/Launcher/](Features/Launcher/)）。
  - 使用显式状态枚举（[Features/Launcher/LauncherState.swift](Features/Launcher/LauncherState.swift)）管理状态，避免布尔变量交叉冲突。
  - [Features/Launcher/LauncherViewModel.swift](Features/Launcher/LauncherViewModel.swift) 统一编排搜索输入、结果过滤、键盘焦点与启动调度。

## 4. 搜索与排序引擎机制

搜索索引为自建纯内存快照，检索过程完全离线且不触碰磁盘，包含严格的 **8 级匹配规则**：

1. **Tier 0（完全匹配）**：应用显示名归一化后与查询完全相同。
2. **Tier 1（前缀匹配）**：应用显示名以此查询开头。
3. **Tier 2（单词前缀）**：应用名称经空格/标点分词后，某个独立单词以此查询开头。
4. **Tier 3（二级元数据）**：应用安装包文件名或 Bundle Identifier 匹配。
5. **Tier 4（别名与首字母）**：配置的自定义别名或名称拉丁/汉字拼音首字母前缀匹配（如 `vsc` 匹配 Visual Studio Code，`wx` 匹配微信）。
6. **Tier 5（全拼前缀）**：汉字显示名转换为无声调拼音后的前缀匹配（如 `weixin` 匹配微信）。
7. **Tier 6（子串包含）**：应用名称中任意位置包含查询词。
8. **Tier 7（模糊跳字）**：按序字符匹配（带跳字惩罚计分）。

**排序规则（Frecency）**：
- 匹配等级（Tier）具有绝对优先权。
- 应用启动次数（对数衰减计分）与最近使用时间（30天衰减计分）**仅用于在同一匹配 Tier 内部打破平局**，绝不会跨 Tier 提权。

## 5. 并发模型与测试契约

- 界面、视图模型与 AppKit 协调者统一标注 `@MainActor`。
- 应用扫描与索引生成等耗时 I/O 任务必须在 Detached Task 后台执行，并通过 `Task.checkCancellation()` 支持协作式取消。
- 禁止使用全局单例替换业务依赖。单元测试中均通过构造用例协议桩（Stub）、内存存储（`MemoryAppUsageStore`）或注入自定义 `AppDependencies` 进行验证。
