import SwiftUI

/// 设置窗口：左侧按分类导航，顶部搜索框按分类名与设置项名称过滤（回车跳到第一个结果）；
/// 右侧只显示当前分类的设置项，在页内独立滚动。
@MainActor
struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @FocusState private var isAPIKeyFocused: Bool
    @FocusState private var isTranslationAPIKeyFocused: Bool
    @State private var selection: SettingsCategory? = .general
    @State private var searchText = ""

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "搜索设置")
        .onSubmit(of: .search) {
            if let first = filteredCategories.first {
                selection = first
            }
        }
        .onChange(of: selection) { oldValue, newValue in
            // 点按侧边栏空白处会取消选中，保持停在原来的分类。
            guard newValue != nil else {
                selection = oldValue
                return
            }
            // 切换分类时 API Key 输入框随页面移除，不会触发失焦保存，先保存已输入的内容。
            viewModel.commitQuickAIAPIKey()
            viewModel.commitTranslationAPIKey()
        }
        // 最小尺寸放得下左右两栏，窗口可拉大与全屏；内容在各页内滚动，窗口不跟随内容的理想高度
        // （见 SettingsWindowController 的 sizingOptions）。
        .frame(minWidth: 760, minHeight: 560)
        .onAppear {
            viewModel.refreshLaunchAtLoginStatus()
            viewModel.refreshPermissionStatus()
        }
    }

    private var filteredCategories: [SettingsCategory] {
        SettingsCategory.filtered(by: searchText)
    }

    private var sidebar: some View {
        List(filteredCategories, selection: $selection) { category in
            Label {
                Text(category.title)
            } icon: {
                SettingsCategoryIcon(category: category)
            }
        }
        .overlay {
            if filteredCategories.isEmpty {
                Text("没有匹配的设置")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationSplitViewColumnWidth(200)
    }

    /// 设置页的最大宽度：窗口拉大或全屏时两侧留白，名称与右侧的开关、按钮不至于隔得太远。
    private static let detailMaxWidth: CGFloat = 640

    private var detail: some View {
        let category = selection ?? .general
        return Form {
            switch category {
            case .general:
                generalSections
            case .search:
                searchSection
            case .quickAI:
                quickAISection
            case .translator:
                translatorSections
            case .environment:
                environmentSection
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: Self.detailMaxWidth)
        .frame(maxWidth: .infinity)
        // 每页从顶部开始显示，不沿用上一页的滚动位置。
        .id(category)
        // 当前分类名显示在右侧顶部、与红绿灯同一行（同系统设置），页内分组不再重复分类名。
        .navigationTitle(category.title)
    }

    // MARK: - 设置页

    @ViewBuilder
    private var generalSections: some View {
        Section {
            Toggle("开机自启动", isOn: launchAtLogin)
            if let notice = viewModel.launchAtLoginNotice {
                launchAtLoginNoticeRow(notice)
            }
            Toggle("开机静默启动", isOn: $viewModel.settings.isSilentLaunchEnabled)
        } footer: {
            Text("开机静默启动开启时，启动 OI 仅驻留菜单栏，不自动呼出启动器面板。")
        }

        Section {
            LabeledContent {
                HStack(spacing: 12) {
                    ShortcutRecorderField(shortcut: viewModel.settings.launcherShortcut) {
                        viewModel.applyLauncherShortcut($0)
                    }
                    Button("恢复默认") {
                        viewModel.applyLauncherShortcut(.defaultLauncher)
                    }
                    .disabled(
                        viewModel.settings.launcherShortcut == .defaultLauncher
                            && viewModel.launcherShortcutNotice == nil
                    )
                }
            } label: {
                Text("呼出快捷键")
            }
            if let notice = viewModel.launcherShortcutNotice {
                shortcutNoticeRow(notice)
            }
        } header: {
            Text("快捷键")
        } footer: {
            Text("全局呼出启动器面板的快捷键，需包含 ⌘、⌥ 或 ⌃ 修饰键；只用 ⌘ 时仅限 Space 与 F 键，以免覆盖各应用的同名快捷键。点按录制后按 Esc 取消。")
        }
    }

    private var searchSection: some View {
        Section {
            Toggle("文件与文件夹搜索", isOn: $viewModel.settings.isFileSearchEnabled)
            Toggle("启动历史排序", isOn: $viewModel.settings.isUsageRankingEnabled)
            Picker("网页搜索引擎", selection: $viewModel.settings.webSearchEngine) {
                ForEach(WebSearchEngine.allCases) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }
        } footer: {
            Text("启动历史排序会记录应用的启动次数与最近使用时间，用于优化常用应用的排序，数据仅保存在本机。在启动器中按 ⌘↩ 会用所选搜索引擎在默认浏览器中搜索输入内容。")
        }
    }

    private var quickAISection: some View {
        Section {
            TextField(
                "接口地址",
                text: $viewModel.settings.quickAIBaseURL,
                prompt: Text("https://api.openai.com/v1")
            )
            .autocorrectionDisabled()
            if viewModel.isQuickAIBaseURLPlaintext {
                Label("API Key 与提问内容将明文传输", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            TextField("模型", text: $viewModel.settings.quickAIModel, prompt: Text("gpt-4o-mini"))
                .autocorrectionDisabled()
            TextField("思考强度", text: $viewModel.settings.quickAIReasoningEffort, prompt: Text("留空不发送"))
                .autocorrectionDisabled()
            SecureField("API Key", text: quickAIAPIKey, prompt: Text("本地模型可留空"))
                .focused($isAPIKeyFocused)
                .onSubmit { viewModel.commitQuickAIAPIKey() }
                .onChange(of: isAPIKeyFocused) { _, isFocused in
                    if !isFocused { viewModel.commitQuickAIAPIKey() }
                }
        } footer: {
            Text(
                """
                在启动器中按 Tab 进入 Quick AI，输入问题后按回车提问。兼容 OpenAI Chat Completions 接口，\
                也可填写 Ollama 等本地服务（如 http://localhost:11434/v1）。提问内容会发送到所填地址，API Key 保存在钥匙串中。\
                思考强度对应接口的 reasoning_effort 参数，常见取值为 low、medium、high，各服务支持的取值不同；\
                留空则不发送，不支持该参数的服务可能报错。
                """
            )
        }
    }

    /// 划词翻译独占一页后拆成三组，原有说明按句分到对应的组。
    @ViewBuilder
    private var translatorSections: some View {
        Section {
            Toggle("触控板用力点按取词", isOn: $viewModel.settings.isForceTouchTranslationEnabled)
            LabeledContent {
                HStack(spacing: 12) {
                    ShortcutRecorderField(shortcut: viewModel.settings.translatorShortcut) {
                        viewModel.applyTranslatorShortcut($0)
                    }
                    Button("恢复默认") {
                        viewModel.applyTranslatorShortcut(.defaultTranslator)
                    }
                    .disabled(
                        viewModel.settings.translatorShortcut == .defaultTranslator
                            && viewModel.translatorShortcutNotice == nil
                    )
                }
            } label: {
                Text("翻译快捷键")
            }
            if let notice = viewModel.translatorShortcutNotice {
                shortcutNoticeRow(notice)
            }
            LabeledContent {
                HStack(spacing: 12) {
                    ShortcutRecorderField(shortcut: viewModel.settings.screenTranslatorShortcut) {
                        viewModel.applyScreenTranslatorShortcut($0)
                    }
                    Button("恢复默认") {
                        viewModel.applyScreenTranslatorShortcut(.defaultScreenTranslator)
                    }
                    .disabled(
                        viewModel.settings.screenTranslatorShortcut == .defaultScreenTranslator
                            && viewModel.screenTranslatorShortcutNotice == nil
                    )
                }
            } label: {
                Text("截图翻译快捷键")
            }
            if let notice = viewModel.screenTranslatorShortcutNotice {
                shortcutNoticeRow(notice)
            }
        } header: {
            Text("取词与快捷键")
        } footer: {
            Text("选中文字后按翻译快捷键即在原处弹出译文，未选中时翻译剪贴板内容；在触控板上用力点按则翻译光标所在的单词；图片、视频字幕、远程桌面等取不到文字时，按截图翻译快捷键框选屏幕区域，在本机识别其中的文字后翻译。")
        }

        Section {
            Picker("目标语言", selection: translationTargetLanguage) {
                languageOptions
            }
            Picker("原文已是目标语言时译为", selection: translationAlternateLanguage) {
                languageOptions
            }
        } header: {
            Text("翻译语言")
        } footer: {
            Text("默认外文译为简体中文、中文译为英语，气泡中可临时切换目标语言。")
        }

        Section {
            TextField(
                "接口地址",
                text: $viewModel.settings.translationBaseURL,
                prompt: Text("https://api.openai.com/v1")
            )
            .autocorrectionDisabled()
            if viewModel.isTranslationBaseURLPlaintext {
                Label("API Key 与翻译内容将明文传输", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            TextField("模型", text: $viewModel.settings.translationModel, prompt: Text("gpt-4o-mini"))
                .autocorrectionDisabled()
            TextField("思考强度", text: $viewModel.settings.translationReasoningEffort, prompt: Text("留空不发送"))
                .autocorrectionDisabled()
            SecureField("API Key", text: translationAPIKey, prompt: Text("本地模型可留空"))
                .focused($isTranslationAPIKeyFocused)
                .onSubmit { viewModel.commitTranslationAPIKey() }
                .onChange(of: isTranslationAPIKeyFocused) { _, isFocused in
                    if !isFocused { viewModel.commitTranslationAPIKey() }
                }
        } header: {
            Text("翻译接口")
        } footer: {
            Text("翻译接口与 Quick AI 分开填写，可以使用不同的服务与模型，建议选用响应快、不带思考的模型，或把思考强度设低（含义同 Quick AI）；原文会发送到所填地址，API Key 保存在钥匙串中。")
        }
    }

    private var environmentSection: some View {
        Section {
            LabeledContent {
                if viewModel.isAccessibilityTrusted {
                    Label("已开启", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("去开启…") {
                        viewModel.requestAccessibilityAccess()
                    }
                }
            } label: {
                guideRow(
                    "开启辅助功能权限",
                    "用于读取其他应用中选中的文字与光标所在的单词，仅在触发翻译时读取；VS Code、Chrome 等应用不提供光标下的文字，用力点按时会模拟双击选中单词，读取后取消选中；读不到单词位置时（如 VS Code）保留选中状态，标出取的是哪个词"
                )
            }
            LabeledContent {
                if viewModel.isScreenCaptureTrusted {
                    Label("已开启", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("去开启…") {
                        viewModel.requestScreenCaptureAccess()
                    }
                }
            } label: {
                guideRow(
                    "开启屏幕录制权限",
                    "仅用于截图翻译：按下快捷键时截取屏幕画面用于定格框选，在本机识别选区中的文字，截图不保存也不上传；开启后需按系统提示重新打开 OI"
                )
            }
            LabeledContent {
                Button("打开触控板设置…") {
                    viewModel.openTrackpadSettings()
                }
            } label: {
                guideRow(
                    "关闭系统查询的用力点按",
                    "在「光标与点按」中把「查询与数据检测器」改为「用三个手指轻点」或关闭，避免系统词典与翻译气泡同时弹出"
                )
            }
            guideRow(
                "保持开启「用力点按和触感反馈」",
                "位于同一页面；关闭后触控板无法识别用力点按"
            )
        } footer: {
            Text("未开启辅助功能权限时，翻译快捷键只能翻译剪贴板内容，用力点按无法取词；未开启屏幕录制权限时无法截图翻译。重新编译或更新 OI 后若取词或截图翻译失效，请在对应的权限列表中移除 OI 后重新添加。")
        }
    }

    // MARK: - 设置行

    private var languageOptions: some View {
        ForEach(TranslationLanguage.allCases) { language in
            Text(language.displayName).tag(language)
        }
    }

    private func guideRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 开机自启动的状态由系统登录项决定，注册失败时需要回退开关，因此不走存储绑定。
    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { viewModel.isLaunchAtLoginEnabled },
            set: { viewModel.setLaunchAtLogin($0) }
        )
    }

    /// 两个翻译语言选成相同时需要互换，因此不走 settings 绑定。
    private var translationTargetLanguage: Binding<TranslationLanguage> {
        Binding(
            get: { viewModel.settings.translationTargetLanguage },
            set: { viewModel.setTranslationTargetLanguage($0) }
        )
    }

    private var translationAlternateLanguage: Binding<TranslationLanguage> {
        Binding(
            get: { viewModel.settings.translationAlternateLanguage },
            set: { viewModel.setTranslationAlternateLanguage($0) }
        )
    }

    /// API Key 写入钥匙串而非设置存储，因此不走 settings 绑定。
    private var quickAIAPIKey: Binding<String> {
        Binding(
            get: { viewModel.quickAIAPIKey },
            set: { viewModel.setQuickAIAPIKey($0) }
        )
    }

    private var translationAPIKey: Binding<String> {
        Binding(
            get: { viewModel.translationAPIKey },
            set: { viewModel.setTranslationAPIKey($0) }
        )
    }

    @ViewBuilder
    private func shortcutNoticeRow(_ notice: GlobalShortcutNotice) -> some View {
        switch notice {
        case .failure(let reason):
            Label("快捷键注册失败：\(reason)", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func launchAtLoginNoticeRow(_ notice: LaunchAtLoginNotice) -> some View {
        switch notice {
        case .approvalPending:
            Label(
                "已提交开机自启动请求，请在 系统设置 → 通用 → 登录项与扩展 中批准。",
                systemImage: "clock.badge.exclamationmark"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        case .failure(let reason):
            Label("设置开机自启动失败：\(reason)", systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }
}

/// 侧边栏的分类图标：白色符号配彩色圆角底，同系统设置的样式。
private struct SettingsCategoryIcon: View {
    let category: SettingsCategory

    var body: some View {
        Image(systemName: category.symbolName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(category.tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

private extension SettingsCategory {
    var tint: Color {
        switch self {
        case .general: .gray
        case .search: .blue
        case .quickAI: .purple
        case .translator: .orange
        case .environment: .indigo
        }
    }
}
