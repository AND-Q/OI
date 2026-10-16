import Foundation

/// State owned by the launcher feature while its application catalog is loaded.
enum LauncherLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

/// Failure banner above the results when the selected item cannot be located (e.g. a moved file).
/// Opening runs in the background after the panel dismisses, so its failures are notified instead.
enum LauncherLaunchState: Equatable, Sendable {
    case idle
    case failed(String)
}

/// State owned by the launcher feature while the file index is queried.
/// Failures degrade silently to an empty file section, so there is no failed case.
enum LauncherFileSearchState: Equatable, Sendable {
    case idle
    case searching
    case loaded
}

/// One row of the results list: selectable results plus non-selectable section headers.
enum LauncherRow: Hashable, Sendable {
    case sectionHeader(String)
    case result(SearchResult)
}

/// One Quick AI question and its streamed answer, shown in place of the results list.
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
        return QuickAIMarkdown.removingThinking(from: answer).isEmpty ? .retry : .copyAndClose
    }
}

/// `↑` / `↓` 滚动 Quick AI 回答区的请求；`serial` 递增保证连续同向按键也会触发。
struct QuickAIScrollRequest: Equatable, Sendable {
    var direction = 0
    var serial = 0
}
