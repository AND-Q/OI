import AppKit
import Quartz

/// Cmd+Y 原生 Quick Look 预览会话：持有 QLPreviewPanel 的数据源并管理其生命周期。
/// QLPreviewPanel 经由 key 窗口的响应链寻找接管者；接管方法挂在 LauncherPanel 上，
/// 再委托到本对象。
@MainActor
final class QuickLookPresenter: NSObject {
    /// 预览会话是否进行中。必须在 QL 面板夺取 key 窗口之前置 true，
    /// 否则启动器面板会把这次失焦误判为需要关闭。
    private(set) var isActive = false
    private var item: URL?
    /// 当前预览的条目 URL（供外部查询与测试断言）。
    var currentPreviewURL: URL? { item }
    /// 预览会话结束后的回调，用于把键盘焦点还给启动器输入框。
    var onSessionEnded: (() -> Void)?
    /// 转发 QLPreviewPanelDelegate 拦截到的未处理按键事件（如方向键、回车、Esc）。
    var onHandleEvent: ((NSEvent) -> Bool)?

    func show(url: URL) {
        item = url
        isActive = true
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        // 面板是 .floating 级别，预览窗保持同级，避免在其他应用的普通窗口之下。
        panel.level = .floating
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    /// 选中项变化后刷新预览内容（方向键跟随）。
    func reloadPreviewItem(with url: URL?) {
        guard isActive else { return }
        item = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.reloadData()
    }

    func close() {
        guard isActive else { return }
        isActive = false
        item = nil
        if let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        }
        if let panel = QLPreviewPanel.shared() {
            if panel.dataSource === self {
                panel.dataSource = nil
            }
            if panel.delegate === self {
                panel.delegate = nil
            }
        }
        onSessionEnded?()
    }

    // MARK: 由 LauncherPanel 转发的接管入口

    func beginControl(in panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self
    }

    func endControl() {
        // AppKit 在 key/main 窗口焦点离开 LauncherPanel 时调用此方法（例如 QL 面板夺取 key 时）。
        // 真正的会话结束由 close() 与 windowWillClose 管理，在此不可提前结束会话。
    }
}

extension QuickLookPresenter: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    // QL 在主线程回调数据源，但协议声明未标注隔离，这里显式断言回到主 actor。
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { item == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        // NSURL 自带 QLPreviewItem 一致性。
        MainActor.assumeIsolated { item as NSURL? }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event else { return false }
        // 同上，QL 在主线程回调，事件只在主线程上使用；NSEvent 不是 Sendable，编译器无从得知，这里显式声明。
        nonisolated(unsafe) let mainThreadEvent = event
        return MainActor.assumeIsolated {
            onHandleEvent?(mainThreadEvent) ?? false
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            guard isActive else { return }
            close()
        }
    }
}
