import CoreGraphics
import Foundation

/// 双击选词：辅助功能取不到光标下的文字时（如 VS Code、Chrome），模拟双击让目标应用选中该处的单词，
/// 读取选区后再单击一次取消选中。用力点按本身会把光标移到点按处，取词结束后目标应用与普通单击一下的状态相同。
/// 取到单词却读不到它的位置时保留选中状态，由目标应用自己标出取的是哪个词。
protocol WordSelecting: Sendable {
    /// 等按键松开后双击 `point`（全局显示坐标）并读取选中的单词；该处不宜双击或没有选中单个词时为 nil。
    func selectWord(at point: CGPoint) async -> CapturedText?
}
