# OI App 搜索实施计划

## 1. 文档目的

本计划只覆盖当前阶段的 App 搜索。目标是先把 OI 做成稳定、快速、可测试的 macOS App 启动器，同时为未来加入文件搜索保留清晰的扩展边界。

本计划不是完整 Spotlight 复刻方案。Apple 的 Spotlight 使用了私有的排序、分类和建议能力，OI 只采用可验证的公开系统能力和本地实现。

## 2. 方案决策

采用：

```text
FileManager 扫描应用目录
    -> 读取 App Bundle 元数据
    -> 构建内存中的应用搜索快照
    -> 精确/前缀/别名/模糊匹配
    -> 匹配质量 + 使用历史排序
    -> NSWorkspace 启动 App
```

当前阶段明确不采用：

- `NSMetadataQuery` 作为 App 的唯一发现来源；
- SQLite 应用索引；
- Rust/FFI 搜索引擎；
- 每次输入都重新扫描磁盘；
- 文件内容、文件夹和系统设置搜索。

### 2.1 选择理由

OI 当前只搜索应用，候选数量通常只有几十到几百个。对三个或几个标准应用目录做一次后台扫描，成本很低，且结果完全可控、可注入测试目录。

`NSMetadataQuery` 更适合未来的文件搜索。将它用于当前 App-only 场景会增加异步通知、索引延迟、隐私设置和 `Sendable` 隔离等复杂度，但不会立即带来相应收益。

Sol 的文件扫描和内存搜索思路适合 OI 当前阶段；Look 的匹配评分、使用历史和快照索引思路值得借鉴，但 SQLite 和跨平台 Rust 架构暂时不需要复制。

## 3. 当前实现基线

当前相关代码：

- `App/AppConfiguration.swift`：提供应用扫描目录；
- `Infrastructure/AppCatalog/FileSystemAppCatalog.swift`：递归发现 `.app` Bundle、读取显示名称并排序；
- `Application/Ports/AppCatalog.swift`：应用发现端口；
- `Application/UseCases/DiscoverApplications.swift`：发现用例和错误转换；
- `Features/Launcher/LauncherViewModel.swift`：加载、查询过滤、选择和启动状态；
- `Infrastructure/Launch/WorkspaceApplicationLauncher.swift`：使用 `NSWorkspace` 启动应用；
- `OITests/LauncherModelTests.swift`：应用目录和 ViewModel 基础测试。

当前查询逻辑是：

```swift
apps.filter {
    $0.name.localizedCaseInsensitiveContains(query)
}
```

当前逻辑已经具备：

- 后台扫描；
- 取消扫描任务；
- `.app` 包发现；
- 隐藏文件和包内部跳过；
- 路径去重；
- 本地化显示名称读取；
- 选中结果启动；
- 空查询时不返回 `selectedApp`。

当前缺少：

- 独立的搜索索引和匹配器；
- Bundle Identifier、Bundle 文件名和别名匹配；
- 前缀、首字母、拼音和模糊搜索；
- 最近使用和使用次数排序；
- 应用安装/删除后的刷新策略；
- 针对搜索排序的独立测试。

## 4. 成功标准

本阶段完成后，应满足：

- 搜索输入路径不执行磁盘递归扫描；
- 精确匹配始终优先于模糊匹配；
- 前缀匹配始终优先于普通包含匹配；
- 使用历史只能在匹配质量相同或接近时参与排序；
- 支持英文 App 名称和本地化名称；
- 支持 Bundle 文件名、Bundle Identifier 或明确配置的别名；
- 中文输入法组合文本不影响原生搜索框占位符；
- 空查询按回车不会启动任何 App；
- 旧搜索结果不能覆盖更新后的 query；
- 应用列表刷新不阻塞面板和输入；
- 构建、单元测试和手工验收全部通过。

## 5. 目标架构

```text
AppCoordinator
    -> LauncherViewModel
        -> DiscoverApplications
            -> AppCatalog
                -> FileSystemAppCatalog
        -> ApplicationSearchIndex
        -> LaunchApplication
            -> WorkspaceApplicationLauncher
        -> AppUsageStore
```

### 5.1 职责边界

`FileSystemAppCatalog`：

- 只负责发现 App 和读取基础元数据；
- 不负责 query 字符串匹配；
- 不负责使用历史；
- 不依赖 SwiftUI。

`ApplicationSearchIndex`：

- 接收应用快照；
- 预计算搜索字段；
- 执行标准化、匹配和评分；
- 返回稳定排序的应用结果；
- 不执行启动和文件系统副作用。

`AppUsageStore`：

- 保存成功启动次数和最近启动时间；
- 不保存完整搜索文本；
- 第一阶段使用 `UserDefaults`，不引入数据库。

`LauncherViewModel`：

- 管理 query、结果、选中项和加载状态；
- 取消过期搜索请求；
- 在成功启动后记录使用历史；
- 不实现字符串评分细节。

`WorkspaceApplicationLauncher`：

- 只负责调用 `NSWorkspace`；
- 将系统启动错误转换为应用层错误。

### 5.2 为未来文件搜索预留的边界

当前阶段不创建文件搜索实现，但搜索索引不要和 App 专属 UI 绑死。未来可以增加：

```text
SearchResult
SearchProvider
ApplicationSearchProvider
SpotlightFileSearchProvider
SearchCoordinator
```

当前 App 搜索可以先保留 `AppDescriptor` 返回类型；在真正接入多种结果时，再把 UI 结果抽象为 `SearchResult`，不要现在为了未来抽象而改动所有层。

## 6. 应用发现设计

### 6.1 默认扫描目录

保留并补充以下目录：

- `/Applications`
- `~/Applications`
- `/System/Applications`
- `/System/Library/CoreServices/Applications`
- `/System/Library/CoreServices/Finder.app/Contents/Applications`

目录仍由 `AppConfiguration` 注入，测试使用临时目录，不依赖用户机器上的真实 App。

### 6.2 扫描规则

扫描器必须：

- 递归查找 `.app` Bundle；
- 使用 `.skipsPackageDescendants`，不进入 App 包内部；
- 支持 `Task.checkCancellation()`；
- 对标准化 URL 路径去重；
- 跳过隐藏目录和不可访问目录；
- 对损坏或无法读取的 Bundle 做单项跳过，不让整个扫描失败；
- 优先读取 `CFBundleDisplayName`，其次读取 `CFBundleName`；
- 没有可用显示名时回退到 Bundle 文件名；
- 不把 App 内的 helper、插件或测试应用当作顶层结果；
- 对符号链接进行明确策略处理，避免同一个 Bundle 重复出现。

### 6.3 身份策略

保留当前 `AppDescriptor.id` 使用标准化路径的兼容性，因为现有测试和未来使用记录可能依赖它。

如果读取到 Bundle Identifier，将它作为使用历史和去重的辅助键：

```text
主身份：标准化 Bundle URL 路径
辅助身份：CFBundleIdentifier
```

两个不同路径具有同一个 Bundle Identifier 时，必须定义保留策略。第一阶段保留路径更浅、位于标准应用目录的版本，并让排序稳定；不要在没有产品规则的情况下随机选择。

## 7. 搜索文档和标准化

新增搜索层内部模型，不把搜索辅助字段直接塞进领域模型：

```swift
struct ApplicationSearchDocument: Sendable {
    let app: AppDescriptor
    let normalizedName: String
    let normalizedBundleName: String
    let normalizedBundleIdentifier: String
    let aliases: [String]
    let initials: String
    let pinyin: String
}
```

### 7.1 搜索字段

每个 App 至少建立：

- 显示名称；
- Bundle 文件名；
- Bundle Identifier；
- 明确配置的别名；
- 英文名称首字母；
- 中文名称首字母或拼音（在技术验证通过后启用）。

示例：

```text
显示名称：Visual Studio Code
Bundle 文件名：Visual Studio Code
Bundle ID：com.microsoft.VSCode
别名：vscode
首字母：vsc
```

### 7.2 标准化规则

查询和索引字段必须使用同一套规则：

- 统一 Unicode 规范化形式；
- 转小写；
- 去除首尾空白；
- 合并连续空白；
- 忽略常见分隔符，如空格、短横线和下划线；
- 拉丁字符去除重音；
- 保留原始名称用于展示；
- 中文转拼音时保留原名，拼音只用于匹配。

拼音实现先验证 Foundation `StringTransform` 对当前系统名称的结果。如果结果不稳定或不支持需要的输入，再单独评估依赖，不在第一步手写完整拼音算法。

## 8. 匹配和排序

### 8.1 匹配层级

使用固定匹配等级，避免使用历史把错误结果推到第一位：

```text
0  名称完全匹配
1  名称前缀匹配
2  单词前缀匹配
3  本地化名称或 Bundle 名称匹配
4  别名/首字母匹配
5  拼音前缀匹配
6  连续包含匹配
7  模糊子序列匹配
```

### 8.2 评分组成

建议使用可测试的结构化分数：

```swift
struct MatchScore: Comparable, Sendable {
    let tier: Int
    let textScore: Int
    let recencyScore: Int
    let usageScore: Int
}
```

排序顺序：

```text
匹配等级
    > 文本位置和连续性
    > 最近启动时间
    > 启动次数（对数衰减）
    > 稳定的名称排序
```

使用历史不能跨越匹配等级。例如，常用的 `Calendar` 不能因为启动次数多而压过名称完全匹配的 `Calculator`。

### 8.3 空查询和边界

- 空字符串：面板保持折叠，不返回可启动的选中项；
- 纯空白：按空查询处理；
- 超长 query：限制长度，避免模糊算法出现不可控开销；
- 无结果：返回空数组；
- 结果上限：由 UI 可见行数决定，建议最多保留 7 条可见结果加少量缓冲；
- 相同分数：按标准化名称和原始名称使用稳定排序；
- 搜索结果中的 URL 必须在启动前再次确认存在或可打开。

## 9. 使用历史

第一阶段使用 `UserDefaults`：

```swift
struct AppUsageRecord: Codable, Sendable {
    var launchCount: Int
    var lastLaunchedAt: Date?
}
```

记录规则：

1. 只有启动用例成功后才增加次数；
2. 更新最近启动时间；
3. 异步持久化，不能阻塞面板关闭或应用启动；
4. 不记录用户输入的 query；
5. 对次数使用上限或对数衰减；
6. 删除 App 后清理记录，或保留有限时间，但必须固定一种策略；
7. 迁移和 key 变更必须保留兼容逻辑。

## 10. 刷新和快照

第一阶段采用完整快照替换：

```text
后台扫描
    -> 构建新数组和新搜索文档
    -> 在主线程一次性替换快照
```

扫描过程不修改当前正在使用的数组。这样搜索始终读取一致的数据，不会看到半更新状态。

### 10.1 刷新时机

- 应用启动时后台扫描；
- 面板显示时使用已有快照；
- 快照为空或过期时触发刷新；
- 启动器关闭时不强制等待刷新；
- 后续可加入 FSEvents 或 `DispatchSource`，watcher 只负责设置 dirty 标记；
- 下一次面板显示或空闲时再执行后台刷新。

不在每个文件事件到达时重建索引，也不在每个 query 改变时扫描磁盘。

## 11. 并发和取消

应用发现和刷新遵循：

```text
开始刷新
    -> 保存 Task
    -> 新刷新到来时取消旧 Task
    -> 扫描中定期检查取消
    -> 完成后检查 Task 未取消
    -> 原子发布新快照
```

搜索本身只读内存快照。若未来模糊匹配成本增加，使用 request ID 保证“最新请求胜出”：

```text
query 改变
    -> requestID + 1
    -> 取消旧任务
    -> 计算结果
    -> 发布前检查 requestID 和 query
```

不得让旧搜索结果覆盖新 query。

## 12. UI 集成规则

- 原生 `TextField("聚焦搜索", text: ...)` 负责占位符和输入法组合态；
- 不在 `ZStack` 中手动画 placeholder；
- query 为空时隐藏结果区域；
- query 非空时显示结果区域；
- 上下键只移动当前结果快照中的选中项；
- 空 query 按回车不启动；
- 点击结果和回车使用同一个启动入口；
- 启动失败时保留错误状态，不记录成功使用历史；
- 搜索结果更新和面板高度更新必须使用最终状态，不读取 `@Published` 的旧值；
- 搜索排序不放在 `LauncherResultsList` 或 AppKit cell 中。

## 13. 实施步骤

### 阶段 0：冻结当前行为

任务：

- 保持现有 `AppCatalog` 和启动用例接口；
- 确认原生 TextField 已替换手动 placeholder；
- 保留空 query 不暴露 `selectedApp` 的保护；
- 为当前扫描和 ViewModel 行为补齐回归测试。

验收：构建成功，现有测试全部通过。

### 阶段 1：补齐应用元数据

任务：

- 抽取 Bundle 元数据读取逻辑；
- 验证显示名称和 Bundle 文件名 fallback；
- 读取 Bundle Identifier 作为搜索和使用历史辅助字段；
- 完善应用目录和嵌套 App 过滤；
- 保持 `AppDescriptor.id` 兼容。

验收：临时 Bundle 测试覆盖英文名称、本地化名称、空名称和损坏 Bundle。

### 阶段 2：建立内存搜索索引

任务：

- 新增 `ApplicationSearchDocument`；
- 新增 `ApplicationSearchIndex`；
- 实现统一标准化；
- 实现完全、前缀、包含匹配；
- 增加 Bundle 名称、Bundle ID 和显式别名匹配；
- 保证相同输入产生稳定顺序。

验收：固定测试数据集对每个 query 得到预期结果和顺序。

### 阶段 3：加入模糊、首字母和拼音

任务：

- 先实现英文首字母匹配；
- 验证 Foundation 拼音转换；
- 再加入中文拼音前缀和首字母；
- 限制模糊匹配的 query 长度和候选数量；
- 对每个匹配等级写边界测试。

验收：`vsc` 可以找到 Visual Studio Code；中文名称和拼音输入结果稳定；错误模糊匹配不会压过准确匹配。

### 阶段 4：加入使用历史

任务：

- 新增 `AppUsageStore`；
- 在成功启动后记录；
- 将最近使用和启动次数加入同等级排序；
- 增加删除 App、异常次数和迁移测试。

验收：常用 App 在同等级内上升，匹配等级顺序不被破坏。

### 阶段 5：快照刷新

任务：

- 新增不可变应用快照；
- 后台扫描并原子替换；
- 添加过期和 dirty 标记；
- 后续接入目录 watcher；
- 在刷新过程中保持旧快照可搜索。

验收：刷新期间输入仍流畅；新安装、删除和移动的 App 在下一次刷新后正确出现或消失。

### 阶段 6：ViewModel 收口

任务：

- 删除 ViewModel 中直接执行字符串过滤的逻辑；
- 由 `ApplicationSearchIndex` 提供结果；
- 保留 ViewModel 的状态、取消和选择职责；
- 将点击和回车统一到同一启动路径；
- 保留面板高度最终值发布修复。

验收：UI 行为不回归，搜索逻辑可以脱离 SwiftUI 单独测试。

## 14. 测试计划

### 14.1 目录和元数据

- 默认目录合并和去重；
- 临时目录扫描 `.app`；
- 跳过 App 包内部内容；
- 符号链接和重复路径；
- 显示名称、本地化名称和文件名 fallback；
- Bundle Identifier 读取失败时的 fallback；
- 不可访问目录不会导致整个扫描失败。

### 14.2 搜索匹配

- 空 query 和空白 query；
- 完全匹配优先；
- 名称前缀优先；
- 单词前缀；
- Bundle 名称和 Bundle ID；
- 别名和首字母；
- 拼音；
- 重音字符和大小写；
- 模糊匹配间隔惩罚；
- 超长 query；
- 稳定 tie-break。

### 14.3 使用历史

- 成功启动增加次数；
- 启动失败不增加次数；
- 最近启动时间排序；
- 使用次数对数衰减；
- 使用历史不能跨越匹配等级；
- App 删除后的记录处理。

### 14.4 异步和刷新

- 扫描任务可取消；
- 新刷新取消旧刷新；
- 旧搜索结果不能覆盖新 query；
- 刷新期间旧快照仍可读取；
- 扫描完成后快照一次性替换。

### 14.5 手工验收

1. 打开面板，原生 placeholder 正常显示；
2. 使用中文输入法输入拼音，组合文字不与 placeholder 重叠；
3. 输入 App 名称，结果及时出现；
4. 输入 `vsc` 或配置别名，得到预期 App；
5. 上下键和回车启动正确 App；
6. 空 query 按回车不会启动第一个 App；
7. 点击结果启动正确 App；
8. 点击面板外部可以关闭；
9. 安装或删除 App 后刷新列表；
10. 双显示器下输入不会导致面板跳屏；
11. 浅色和深色模式下图标、选中行和搜索框正常。

## 15. 风险和处理

### Spotlight 索引状态

当前 App 发现不依赖 Spotlight，因此索引关闭、延迟或隐私排除不会使启动器失效。

### 扫描耗时

扫描在后台进行，候选数量小，第一阶段不需要 SQLite。若未来实测扫描时间明显增加，再增加缓存和 dirty 刷新，不直接引入数据库。

### 拼音质量

中文多音字和本地化名称可能产生不稳定转写。拼音只作为低优先级匹配字段，不能影响原名匹配；出现质量问题时可以关闭该字段而不影响基础搜索。

### 重复 App

不同路径可能包含同一个 App。第一阶段使用标准化路径去重，并对 Bundle Identifier 相同的结果制定稳定保留规则；不要简单依赖数组顺序。

### 使用历史隐私

只保存实际启动的 App ID、次数和时间，不保存原始 query，不上传任何数据。

## 16. 完成检查清单

- [ ] 应用发现和搜索匹配职责分离；
- [ ] 搜索输入路径没有磁盘递归扫描；
- [ ] 元数据 fallback 和去重规则固定；
- [ ] 完全、前缀、别名和模糊匹配可测试；
- [ ] 中文名称和拼音匹配经过验证；
- [ ] 使用历史不破坏匹配质量；
- [ ] 快照刷新可取消且不阻塞 UI；
- [ ] 空 query、输入法和回车有回归测试；
- [ ] 现有构建和测试通过；
- [ ] 没有引入 `NSMetadataQuery`、SQLite、Rust 或文件搜索；
- [ ] 文档中的未来文件搜索接口尚未提前污染当前 App-only 实现。
