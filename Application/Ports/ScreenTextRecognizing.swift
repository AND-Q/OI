import CoreGraphics
import Foundation

/// 截图翻译：进入框选时定格各块屏幕的画面，框选完成后识别画面中选区内的文字。截屏与识别都在本机完成，
/// 截图只在内存中、不保存也不上传；两者耗时较长，实现须在后台执行，异步方法不得占用主线程。
protocol ScreenTextRecognizing: Sendable {
    /// 截取每块屏幕当前的画面，OI 自己的窗口不入镜。
    /// 截屏失败（如未获屏幕录制权限、授权后尚未重新打开 OI）时抛错。
    func captureScreens() async throws -> ScreenSnapshot

    /// `snapshot` 中 `rect`（全局显示坐标）区域内识别出的文字，已整理成段落；没有文字时为空字符串。
    func recognizeText(in rect: CGRect, of snapshot: ScreenSnapshot) async throws -> String
}

/// 定格的屏幕画面：框选期间铺在遮罩下面，识别也只基于这一帧，屏幕内容之后的变化不影响选区。
/// `CGImage` 不可变，可以跨线程传递。
struct ScreenSnapshot: @unchecked Sendable {
    struct Display {
        let displayID: CGDirectDisplayID
        /// 屏幕在全局显示坐标中的位置（原点在主屏左上角、y 轴向下）。
        let frame: CGRect
        /// 整块屏幕的画面，按屏幕像素截取。
        let image: CGImage
    }

    let displays: [Display]
}
