# OI

OI 是一个原生 macOS 菜单栏启动器模板：使用 `⌥Space` 呼出启动器，搜索已安装的 App，并启动选中的应用。

## 架构定位

项目采用“单 App Target + 明确分层 + Composition Root”的架构。它适合当前小功能，也为后续设置页、文件搜索、插件和网络功能预留了稳定边界。它不是为了目录数量而分层，也不是过早拆成多个 Swift Package。

```text
App/                         Composition Root
  OIApp.swift                SwiftUI 生命周期入口
  AppDelegate.swift          NSApplication 生命周期适配
  AppConfiguration.swift     可变配置（扫描路径、快捷键）
  AppDependencies.swift      唯一的具体依赖组装点
  AppCoordinator.swift       启动、停止和 AppKit 生命周期协调

Domain/                      业务核心，不依赖 AppKit/SwiftUI
  Models/AppDescriptor.swift 纯业务数据

Application/                 用例边界和外部端口
  Ports/                     AppCatalog、ApplicationLaunching 等协议
  UseCases/                  发现和启动应用等业务流程
  Errors/                    面向 Feature 的稳定错误模型

Features/Launcher/           用户功能和状态
  LauncherState.swift        可测试的加载与启动状态
  LauncherViewModel.swift    搜索、选择和异步任务协调
  LauncherView.swift         SwiftUI 界面

Infrastructure/              系统能力实现
  AppCatalog/                文件系统扫描
  Launch/                    NSWorkspace 启动实现
  Shortcut/                  Carbon 全局快捷键实现

UI/                          AppKit/SwiftUI 桥接
  Icons/                     NSImage 图标提供与缓存
  Panel/                     NSPanel 和键盘事件适配
  StatusBar/                 NSStatusItem 适配

Assets.xcassets/             App 图标与全局 Accent Color
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

正式发布前需要配置签名团队、递增 `CURRENT_PROJECT_VERSION`，配置发布所需的 entitlement，并完成 Archive、Developer ID 签名和 notarization。App Sandbox 是否启用应按发布渠道和需要的系统权限决定：本启动器扫描系统应用并注册全局快捷键，不应为了形式而启用一个无法满足实际能力的 sandbox 配置。
