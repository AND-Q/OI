import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @FocusState private var isAPIKeyFocused: Bool

    var body: some View {
        Form {
            Section {
                Toggle("开机自启动", isOn: launchAtLogin)
                if let notice = viewModel.launchAtLoginNotice {
                    launchAtLoginNoticeRow(notice)
                }
                Toggle("开机静默启动", isOn: $viewModel.settings.isSilentLaunchEnabled)
            } header: {
                Text("通用")
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
                            viewModel.applyLauncherShortcut(.standard)
                        }
                        .disabled(
                            viewModel.settings.launcherShortcut == .standard
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
                Text("全局呼出启动器面板的快捷键，需包含 ⌘、⌥ 或 ⌃ 修饰键。点按录制后按 Esc 取消。")
            }

            Section {
                Toggle("文件与文件夹搜索", isOn: $viewModel.settings.isFileSearchEnabled)
                Toggle("启动历史排序", isOn: $viewModel.settings.isUsageRankingEnabled)
            } header: {
                Text("搜索")
            } footer: {
                Text("启动历史排序会记录应用的启动次数与最近使用时间，用于优化常用应用的排序，数据仅保存在本机。")
            }

            Section {
                TextField(
                    "接口地址",
                    text: $viewModel.settings.quickAIBaseURL,
                    prompt: Text("https://api.openai.com/v1")
                )
                .autocorrectionDisabled()
                if viewModel.isQuickAIBaseURLPlaintext {
                    Label("API Key 与提问、翻译内容将明文传输", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                TextField("模型", text: $viewModel.settings.quickAIModel, prompt: Text("gpt-4o-mini"))
                    .autocorrectionDisabled()
                SecureField("API Key", text: quickAIAPIKey, prompt: Text("本地模型可留空"))
                    .focused($isAPIKeyFocused)
                    .onSubmit { viewModel.commitQuickAIAPIKey() }
                    .onChange(of: isAPIKeyFocused) { _, isFocused in
                        if !isFocused { viewModel.commitQuickAIAPIKey() }
                    }
            } header: {
                Text("Quick AI")
            } footer: {
                Text("在启动器中按 Tab 进入 Quick AI，输入问题后按回车提问。兼容 OpenAI Chat Completions 接口，也可填写 Ollama 等本地服务（如 http://localhost:11434/v1）。提问内容会发送到所填地址，API Key 保存在钥匙串中。")
            }

            Section {
                Toggle("触控板用力点按取词", isOn: $viewModel.settings.isForceTouchTranslationEnabled)
                LabeledContent {
                    HStack(spacing: 12) {
                        ShortcutRecorderField(shortcut: viewModel.settings.translatorShortcut) {
                            viewModel.applyTranslatorShortcut($0)
                        }
                        Button("恢复默认") {
                            viewModel.applyTranslatorShortcut(.standardTranslator)
                        }
                        .disabled(
                            viewModel.settings.translatorShortcut == .standardTranslator
                                && viewModel.translatorShortcutNotice == nil
                        )
                    }
                } label: {
                    Text("翻译快捷键")
                }
                if let notice = viewModel.translatorShortcutNotice {
                    shortcutNoticeRow(notice)
                }
                Picker("目标语言", selection: translationTargetLanguage) {
                    languageOptions
                }
                Picker("原文已是目标语言时译为", selection: translationAlternateLanguage) {
                    languageOptions
                }
            } header: {
                Text("划词翻译")
            } footer: {
                Text("选中文字后按翻译快捷键，或在触控板上用力点按，即在原处弹出译文；未选中时用力点按会取光标所在的单词，按快捷键则翻译剪贴板内容。默认外文译为简体中文、中文译为英语，气泡中可临时切换目标语言。翻译使用上方 Quick AI 的接口，原文会发送到所填地址。")
            }

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
            } header: {
                Text("取词环境")
            } footer: {
                Text("未开启辅助功能权限时，翻译快捷键只能翻译剪贴板内容，用力点按无法取词。重新编译或更新 OI 后若取词失效，请在辅助功能列表中移除 OI 后重新添加。")
            }
        }
        .formStyle(.grouped)
        // 固定高度、内容在表单内滚动：窗口按 preferredContentSize 跟随理想高度时，
        // 分组增多后理想高度超出屏幕，窗口被压回又被撑大，会触发约束更新死循环崩溃。
        .frame(width: 480, height: 560)
        .onAppear {
            viewModel.refreshLaunchAtLoginStatus()
            viewModel.refreshPermissionStatus()
        }
    }

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

    @ViewBuilder
    private func shortcutNoticeRow(_ notice: LauncherShortcutNotice) -> some View {
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
