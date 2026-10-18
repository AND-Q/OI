# OI

OI 是一个原生 macOS 菜单栏启动器：按 `⌥Space` 呼出 Spotlight 风格的面板，搜索并打开 App 与文件，也能做计算、打开网址、向 AI 提问，并在任意应用中用力点按或按 `⌥D` 划词翻译。

## 功能

- **应用搜索**：支持中英文名、拼音全拼与首字母（`weixin`、`wx` 都能找到微信）和模糊匹配；同级匹配内按使用频次排序，索引完全离线。
- **文件搜索**：基于系统 Spotlight 索引检索家目录下的文件与文件夹，排在 App 之后。
- **快速查询**：输入算式即时求值，输入 `ip` 查询本机局域网地址，`Enter` 复制结果。
- **网址与网页搜索**：输入网址直接打开；`⌘Enter` 用所选搜索引擎（必应、Google、百度、DuckDuckGo）搜索当前输入。
- **结果操作**：`⌘F` 在 Finder 中显示，`⌘Y` 用 Quick Look 预览，`⌘K` 打开快捷操作菜单。
- **Quick AI**：按 `Tab` 向 OpenAI 兼容接口（也可以是 Ollama 等本地模型）提问，流式显示 Markdown 回答。
- **划词翻译**：触控板用力点按翻译光标下的单词，`⌥D` 翻译选中的文字或剪贴板，`⌥⇧D` 框选屏幕区域识别文字后翻译，译文在原文旁的气泡中流式显示。
- **设置**：开机自启、自定义快捷键、文件搜索与使用历史开关、网页搜索引擎、Quick AI 与划词翻译各自的接口、翻译语言。

完整说明见 [OI 功能清单](docs/OI%20功能清单.md) 与 [OI 使用指南](docs/OI%20使用指南.md)。

## 系统要求与权限

- macOS 27.0 或更高版本。OI 常驻系统菜单栏，没有 Dock 图标；设置窗口打开期间临时显示 Dock 图标，可用 `⌘Tab` 切回，关闭后恢复。
- 文件搜索需要桌面、文稿、下载目录的访问授权，首次启动时请求；在设置中关闭文件搜索后不再请求。
- 划词翻译需要「辅助功能」权限（系统设置 → 隐私与安全性 → 辅助功能），截图翻译需要「屏幕录制」权限（系统设置 → 隐私与安全性 → 屏幕与系统录音），设置窗口中都有授权入口；截图只在本机识别，不保存也不上传。
- 回车打开应用或文件失败时以系统通知说明原因，第一次需要时才请求通知权限。
- Quick AI 与划词翻译需要在设置中分别填写接口地址与模型（可以使用不同的服务），API Key 保存在钥匙串中。只有这两个功能会发起网络请求，其余检索都在本地完成。

## 架构定位

项目采用“单 App Target + 明确分层 + Composition Root”的架构。目前的应用与文件搜索、设置、Quick AI 和划词翻译都在这套边界内实现，后续的插件等功能也沿用同样的分层。它不是为了目录数量而分层，也不是过早拆成多个 Swift Package。

```text
App/                         Composition Root
  OIApp.swift                SwiftUI 生命周期入口
  AppDelegate.swift          NSApplication 生命周期适配
  AppConfiguration.swift     可变配置（扫描路径等，快捷键已移入用户设置）
  AppDependencies.swift      唯一的具体依赖组装点
  AppCoordinator.swift       启动、停止和 AppKit 生命周期协调

Domain/                      业务核心，不依赖 AppKit/SwiftUI
  Models/                    App、文件、搜索结果、快速查询、翻译语言等纯业务数据

Application/                 用例边界和外部端口
  Ports/                     AppCatalog、ApplicationLaunching 等协议
  UseCases/                  发现和启动应用、搜索文件、Quick AI 问答、翻译等业务流程
  Search/                    应用搜索索引与拼音、首字母归一化
  Errors/                    面向 Feature 的稳定错误模型

Features/Launcher/           用户功能和状态
  LauncherState.swift        可测试的加载与启动状态
  LauncherViewModel.swift    搜索、选择和异步任务协调
  LauncherLayout.swift       面板布局尺寸与展开高度
  LauncherActionMenu.swift   ⌘K 快捷操作菜单
  QuickQueryResolver.swift   算式求值与本机 IP 查询
  WebURLResolver.swift       网址识别
Features/Settings/           设置状态与快捷键展示
Features/Translator/         划词翻译的状态、视图模型与气泡视图
Features/Shared/             多个功能共用的呈现逻辑（Markdown 解析、流式文本缓冲）

Infrastructure/              系统能力实现
  AppCatalog/                文件系统扫描与应用目录监听
  FileSearch/                Spotlight 文件检索
  Launch/                    NSWorkspace 打开应用、文件与网址
  Shortcut/                  Carbon 全局快捷键实现
  LoginItem/                 SMAppService 开机自启动实现
  QuickAI/                   OpenAI 兼容接口客户端与钥匙串存储
  Translator/                辅助功能取词、用力点按监听、双击选词、截图识字与语种识别
  Notifications/             系统通知中心提示（后台打开失败）
  Settings/                  UserDefaults 用户设置
  Usage/                     UserDefaults 启动历史

UI/                          AppKit/SwiftUI 桥接
  Icons/                     NSImage 图标提供与缓存
  Panel/                     NSPanel、启动器界面、Quick Look 与键盘事件适配
  StatusBar/                 NSStatusItem 适配
  Settings/                  设置窗口、表单与快捷键录制
  Translator/                翻译气泡面板、单词高亮与截图框选

Assets.xcassets/             App 图标与全局 Accent Color
assets/AppIcon.svg           App 图标源文件
docs/                        功能清单、使用指南与待办
```

依赖方向：

```text
App -> Features -> Application -> Domain
App -> Infrastructure -> Application / Domain
App -> UI -> Features / Application / Domain
```

`App` 是唯一的组装入口。Feature 不创建具体基础设施；Domain 不引用 AppKit、SwiftUI 或 Carbon；系统 API 只能出现在 Infrastructure 和 UI 适配层。UI 层可以依赖 Application/Domain，但 Infrastructure 不得依赖 Feature 或 UI。

## 架构契约

- 具体实现只能由 `AppDependencies.live(configuration:)` 创建。测试通过构造 use case、port stub 或 `AppDependencies` 替换依赖，不使用全局单例替换业务依赖。
- 所有跨层副作用先以 `Application/Ports` 表达，再由 `Infrastructure` 实现。`Application` 用例负责把底层错误转换为稳定的 `ApplicationError`；Feature 再将其映射为界面文案。
- Feature 使用显式状态类型，避免多个布尔值形成相互矛盾的加载、失败和提交状态。
- UI 专属类型（例如 `NSImage`、`NSPanel`、`NSStatusItem`）只存在于 `UI`。`Domain` 模型保持 Foundation-only 和 `Sendable`。
- `@MainActor` 只覆盖界面、AppKit 协调和它们的协议；文件扫描等耗时操作在后台执行，支持取消。
- 当前保持单一 app target。只有当模块具有独立编译边界、独立所有者或显著构建收益时，才提取本地 Swift Package。

## 扩展规则

- 新业务模型放在 `Domain/Models`，保持 Foundation-only、可测试、可 `Sendable`。
- 新用例和系统能力接口先在 `Application/Ports` 定义协议，再在 `Infrastructure` 实现。
- 新用户流程新增独立 Feature，不把状态塞进 `LauncherViewModel`。
- 图标、窗口、菜单栏、键盘事件等表现层能力不要进入 Domain。
- 不创建没有实际职责的 `Manager`、`Service`、`Repository`、空目录或 DTO；新增抽象必须消除真实耦合或重复。

## 构建与测试

使用完整 Xcode 打开 `OI.xcodeproj`，选择共享的 `OI` scheme。最低部署版本为 macOS 27.0，测试 target 为 `OITests`。Debug、Release 和测试 target 都开启了完整严格并发检查；Release 启用 Hardened Runtime。

命令行构建：

```bash
xcodebuild -project OI.xcodeproj -scheme OI -configuration Debug build
xcodebuild -project OI.xcodeproj -scheme OI -configuration Debug test
```

## 发布

OI 通过 GitHub Release 分发安装包，不上架 App Store，也不使用 Developer ID 签名和公证，安装包为本地临时签名（ad-hoc）。发布一个版本：

1. 递增 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`，在 `docs/releases/v<版本号>.md` 编写发布说明，提交后运行全部测试。
2. 执行 `scripts/release.sh`：编译 Release 版，打包为 `build/release/OI-<版本号>.zip`，并生成带 SHA-256 的发布说明。也可以在 Xcode 中 Archive，再通过 Distribute App → Custom → Copy App 导出 `OI.app` 后在 Finder 中压缩。
3. 用脚本最后打印的 `gh release create` 命令发布，或在 GitHub 网页上创建 Release 并上传安装包。

不启用 App Sandbox：OI 需要扫描系统应用、注册全局快捷键并通过辅助功能读取其他应用的文字，沙盒无法满足这些能力。
