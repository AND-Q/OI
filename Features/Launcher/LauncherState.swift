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

/// 一段 Quick AI 对话：按轮次往下排列的提问与流式到达的回答，显示在结果列表的位置。
/// 至少有一轮，只有最后一轮可能仍在输出。
struct QuickAISession: Equatable, Sendable {
    /// 一轮提问与回答。
    struct Turn: Equatable, Sendable {
        enum State: Equatable, Sendable {
            case streaming
            case finished
            /// 输出到一半被中断（关闭面板等），保留已经收到的内容。
            case interrupted
            case failed(String)
        }

        let question: String
        var answer = ""
        var state: State = .streaming

        /// 显示、复制与发给模型的回答，不含 `<think>` 推理内容。
        var visibleAnswer: String { MarkdownParser.removingThinking(from: answer) }
    }

    private(set) var turns: [Turn]
    /// 这段对话使用的模型（开始对话时设置中填写的模型名），显示在标题栏；未填写时为空。
    let modelName: String
    /// `Cmd+C` 复制后在追问框右端给出反馈；显示一会儿后、回答继续增长或开始新的一轮时复位。
    var isAnswerCopied = false

    init(question: String, modelName: String = "") {
        turns = [Turn(question: question)]
        self.modelName = modelName
    }

    /// 最后一轮：流式增量写入这一轮，重试也只重来这一轮。
    var lastTurn: Turn {
        get { turns[turns.count - 1] }
        set { turns[turns.count - 1] = newValue }
    }

    var isStreaming: Bool { lastTurn.state == .streaming }

    /// 追问：在末尾开始新的一轮。
    mutating func append(question: String) {
        turns.append(Turn(question: question))
        isAnswerCopied = false
    }

    /// 重试：清空最后一轮的回答，以同一个问题重新输出。
    mutating func restartLastTurn() {
        lastTurn = Turn(question: lastTurn.question)
        isAnswerCopied = false
    }

    /// 最后一轮之前、随最后一轮的提问发给模型的问答：只含有可见回答的轮次（输出到一半失败的部分回答也算），
    /// 没有回答的失败轮次不发送。
    var history: [AIConversationTurn] {
        turns.dropLast().compactMap { turn in
            let answer = turn.visibleAnswer
            return answer.isEmpty ? nil : AIConversationTurn(question: turn.question, answer: answer)
        }
    }

    /// 复制（`Enter` / `Cmd+C`）用的最后一条回答：最近一条有可见内容的回答，都没有时为 nil。
    var answerToCopy: String? {
        turns.lazy.map(\.visibleAnswer).last(where: { !$0.isEmpty })
    }

    /// 回车在当前状态下的作用，面板按键与追问框右端的提示共用同一判断。
    enum ReturnAction: Equatable, Sendable {
        case none
        case followUp
        case copyAndClose
        case retry
    }

    /// 输出期间不响应；输入框有文字（`hasDraft`）时追问；最后一轮失败（含输出到一半失败）、被中断或没有可复制的内容时
    /// 重试这一轮；否则复制并关闭。
    func returnAction(hasDraft: Bool) -> ReturnAction {
        if isStreaming { return .none }
        if hasDraft { return .followUp }
        switch lastTurn.state {
        case .failed, .interrupted:
            return .retry
        case .streaming, .finished:
            return lastTurn.visibleAnswer.isEmpty ? .retry : .copyAndClose
        }
    }
}

/// `↑` / `↓` 滚动 Quick AI 回答区的请求；`serial` 递增保证连续同向按键也会触发。
struct QuickAIScrollRequest: Equatable, Sendable {
    var direction = 0
    var serial = 0
}
