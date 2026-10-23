import Foundation

/// 启动器加载应用目录的状态。
enum LauncherLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

/// 选中项无法定位（如文件已被移动）时结果列表上方的失败横幅。
/// 打开在面板收起后于后台进行，打开失败改由系统通知告知。
enum LauncherLaunchState: Equatable, Sendable {
    case idle
    case failed(String)
}

/// 启动器查询文件索引的状态。
/// 查询失败时文件分组静默留空，因此没有失败状态。
enum LauncherFileSearchState: Equatable, Sendable {
    case idle
    case searching
    case loaded
}

/// 结果列表的一行：可选中的结果，或不可选中的分组标题。
enum LauncherRow: Hashable, Sendable {
    case sectionHeader(String)
    case result(SearchResult)
}

/// 一次 Quick AI 提问及其流式到达的回答，显示在结果列表的位置。
struct QuickAISession: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case streaming
        case finished
        case failed(String)
    }

    let question: String
    var answer = ""
    var state: State = .streaming
    /// `Cmd+C` 复制后在页脚给出反馈；回答继续增长时复位。
    var isAnswerCopied = false

    var isStreaming: Bool { state == .streaming }

    /// 回车在当前状态下的作用，面板按键与页脚提示共用同一判断。
    enum ReturnAction: Equatable, Sendable {
        case none
        case copyAndClose
        case retry
    }

    /// 输出期间不响应；失败（含输出到一半失败）或没有可复制的内容时重试；否则复制并关闭。
    var returnAction: ReturnAction {
        if isStreaming { return .none }
        if case .failed = state { return .retry }
        return MarkdownParser.removingThinking(from: answer).isEmpty ? .retry : .copyAndClose
    }
}

/// `↑` / `↓` 滚动 Quick AI 回答区的请求；`serial` 递增保证连续同向按键也会触发。
struct QuickAIScrollRequest: Equatable, Sendable {
    var direction = 0
    var serial = 0
}
