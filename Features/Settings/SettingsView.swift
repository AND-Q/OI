import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

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
                Toggle("文件与文件夹搜索", isOn: $viewModel.settings.isFileSearchEnabled)
                Toggle("启动历史排序", isOn: $viewModel.settings.isUsageRankingEnabled)
            } header: {
                Text("搜索")
            } footer: {
                Text("启动历史排序会记录应用的启动次数与最近使用时间，用于优化常用应用的排序，数据仅保存在本机。")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear { viewModel.refreshLaunchAtLoginStatus() }
    }

    /// 开机自启动的状态由系统登录项决定，注册失败时需要回退开关，因此不走存储绑定。
    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { viewModel.isLaunchAtLoginEnabled },
            set: { viewModel.setLaunchAtLogin($0) }
        )
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
