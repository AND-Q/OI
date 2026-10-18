import CoreGraphics
import Foundation

/// 截图翻译：识别屏幕上框选区域中的文字。截屏与识别都在本机完成，截图不保存也不上传；
/// 两者耗时较长，实现须在后台执行，异步方法不得占用主线程。
protocol ScreenTextRecognizing: Sendable {
    /// `rect`（全局显示坐标）区域中识别出的文字，已整理成段落；没有文字时为空字符串。
    /// 截屏失败（如未获屏幕录制权限、授权后尚未重新打开 OI）时抛错。
    func recognizeText(in rect: CGRect) async throws -> String
}
