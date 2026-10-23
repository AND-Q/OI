import AppKit
import SwiftUI
import os

/// 检查更新：从菜单栏选择「检查更新…」时查询 GitHub 上最新发布的版本，用提醒框告知结果；
/// 有新版本时可一键打开发布页下载。不在后台自动检查。
@MainActor
final class UpdateCheckController {
    /// 检查的结果，决定提醒框的内容。
    enum Outcome: Equatable {
        case checked(UpdateCheckResult)
        case failed(reason: String)
    }

    private let checkForUpdates: CheckForUpdates
    private let openURL: OpenURL
    /// 展示提醒框，返回用户是否选择了「前往下载」；测试替换为记录。
    private let showAlert: @MainActor (Outcome) -> Bool
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "OI", category: "UpdateCheck")

    /// 正在查询；期间菜单项不可点按，避免重复请求。
    private(set) var isChecking = false

    init(
        checkForUpdates: CheckForUpdates,
        openURL: OpenURL,
        showAlert: @escaping @MainActor (Outcome) -> Bool = { UpdateCheckController.runAlert($0) }
    ) {
        self.checkForUpdates = checkForUpdates
        self.openURL = openURL
        self.showAlert = showAlert
    }

    func check() async {
        guard !isChecking else { return }
        isChecking = true
        let outcome: Outcome
        do {
            outcome = .checked(try await checkForUpdates.execute())
        } catch ApplicationError.updateCheckFailed(let reason) {
            outcome = .failed(reason: reason)
        } catch {
            outcome = .failed(reason: error.localizedDescription)
        }
        // 提醒框打开期间菜单项恢复可用：查询已经结束。
        isChecking = false
        guard showAlert(outcome), case .checked(.updateAvailable(_, _, let release)) = outcome else { return }
        do {
            try await openURL.execute(release.pageURL)
        } catch {
            logger.error("Opening release page failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 更新日志开头的一级标题（发布说明以「# OI 1.2.0」开头）与提醒框标题重复，不再显示。
    static func releaseNoteBlocks(from notes: String) -> [MarkdownBlock] {
        var blocks = MarkdownParser.blocks(from: notes)
        if case .heading(1, _)? = blocks.first {
            blocks.removeFirst()
        }
        return blocks
    }

    /// 用系统提醒框展示结果。与设置窗口、关于面板一致，先用 activate(ignoringOtherApps:) 激活，
    /// 提醒框才会出现在其他应用之上并获得键盘焦点。
    static func runAlert(_ outcome: Outcome) -> Bool {
        let panel = NSAlert()
        switch outcome {
        case .checked(.updateAvailable(let current, let latest, let release)):
            panel.messageText = "OI \(latest) 已发布"
            panel.informativeText = "当前版本为 \(current)。下载 dmg 后打开，把 OI 拖到「应用程序」文件夹替换旧版本。"
            let blocks = releaseNoteBlocks(from: release.notes)
            if !blocks.isEmpty {
                let notesView = NSHostingView(rootView: ReleaseNotesView(blocks: blocks))
                // 只按这里给定的尺寸排版，更新日志在框内滚动，不随内容撑大提醒框。
                notesView.sizingOptions = []
                notesView.frame = NSRect(x: 0, y: 0, width: 400, height: 240)
                panel.accessoryView = notesView
            }
            panel.addButton(withTitle: "前往下载")
            panel.addButton(withTitle: "以后再说").keyEquivalent = "\u{1b}"
        case .checked(.upToDate(let current)):
            panel.messageText = "OI 已是最新版本"
            panel.informativeText = "当前版本 \(current) 是最新版本。"
            panel.addButton(withTitle: "好")
        case .failed(let reason):
            panel.alertStyle = .warning
            panel.messageText = "检查更新失败"
            panel.informativeText = reason
            panel.addButton(withTitle: "好")
        }
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        guard case .checked(.updateAvailable) = outcome else { return false }
        return response == .alertFirstButtonReturn
    }
}

/// 提醒框中的更新日志：按 Markdown 显示，在框内滚动，文字可选中复制。
private struct ReleaseNotesView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    MarkdownBlockView(block: block)
                }
            }
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
