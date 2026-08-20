# OI

OI 是一个原生 macOS 菜单栏启动器模板：使用 `⌥Space` 呼出启动器，搜索已安装的 App，并启动选中的应用。

## 架构定位

项目采用“单 App Target + 明确分层 + Composition Root”的架构。它适合当前小功能，也为后续设置页、文件搜索、插件和网络功能预留了稳定边界。

```text
App/                         Composition Root
  OIApp.swift                SwiftUI 生命周期入口
  AppDelegate.swift          NSApplication 生命周期适配
  AppCoordinator.swift       依赖组装、启动和停止

Domain/                      业务核心，不依赖 AppKit/SwiftUI
  Models/AppDescriptor.swift 纯业务数据

Application/                 用例边界和外部端口
  Ports/                     AppCatalog、ApplicationLaunching 等协议
  UseCases/                  发现和启动应用等业务流程

Features/Launcher/           用户功能和状态
  LauncherViewModel.swift    搜索、选择、加载状态
  LauncherView.swift         SwiftUI 界面

Infrastructure/              系统能力实现
  AppCatalog/                文件系统扫描
  Icons/                     NSWorkspace 图标实现
  Launch/                    NSWorkspace 启动实现
  Shortcut/                  Carbon 全局快捷键实现

UI/                          AppKit/SwiftUI 桥接
  Panel/                     NSPanel 和键盘事件适配
  StatusBar/                 NSStatusItem 适配
  Shared/                    UI 服务协议
```

依赖方向：

```text
App -> Features -> Application -> Domain
App -> Infrastructure -> Application / Domain
App -> UI -> Features / Application / Domain
```

`App` 是唯一的组装入口。Feature 不创建具体基础设施；Domain 不引用 AppKit、SwiftUI 或 Carbon；系统 API 只能出现在 Infrastructure 和 UI 适配层。

## 扩展规则

- 新业务模型放在 `Domain/Models`，保持 Foundation-only、可测试、可 `Sendable`。
- 新用例和系统能力接口先在 `Application/Ports` 定义协议，再在 `Infrastructure` 实现。
- 新用户流程新增独立 Feature，不把状态塞进 `LauncherViewModel`。
- 图标、窗口、菜单栏、键盘事件等表现层能力不要进入 Domain。
- 只有在多个 Feature 形成稳定边界后，再拆分本地 Swift Package；当前单 target 可以避免过早模块化。

## 构建与测试

使用完整 Xcode 打开 `OI.xcodeproj`，选择共享的 `OI` scheme。最低部署版本为 macOS 13.0，测试 target 为 `OITests`。

命令行构建：

```bash
xcodebuild -project OI.xcodeproj -scheme OI -configuration Debug build
xcodebuild -project OI.xcodeproj -scheme OI -configuration Debug test
```

正式发布前需要替换 Bundle ID、签名团队、版本号，并补充 Hardened Runtime、entitlements、Archive 和 notarization 配置。
