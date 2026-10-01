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
                    launcherShortcutNoticeRow(notice)
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
        }
        .formStyle(.grouped)
        // 固定高度、内容在表单内滚动：窗口按 preferredContentSize 跟随理想高度时，
        // 分组增多后理想高度超出屏幕，窗口被压回又被撑大，会触发约束更新死循环崩溃。
        .frame(width: 480, height: 560)
        .onAppear { viewModel.refreshLaunchAtLoginStatus() }
    }

    /// 开机自启动的状态由系统登录项决定，注册失败时需要回退开关，因此不走存储绑定。
    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { viewModel.isLaunchAtLoginEnabled },
            set: { viewModel.setLaunchAtLogin($0) }
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
    private func launcherShortcutNoticeRow(_ notice: LauncherShortcutNotice) -> some View {
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
