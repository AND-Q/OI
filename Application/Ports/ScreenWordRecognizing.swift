import CoreGraphics
import Foundation

/// 截图识字：识别屏幕上指定位置的单词，用于不通过辅助功能接口提供文字的应用（如 VS Code、Chrome）。
/// 截屏与识别耗时较长，实现须在后台执行。
protocol ScreenWordRecognizing: Sendable {
    /// `point`（全局显示坐标）处的单词；该处没有可识别的文字或未获屏幕录制权限时为 nil。
    func word(at point: CGPoint) async -> CapturedText?
}
