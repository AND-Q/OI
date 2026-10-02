import Foundation

/// 流式增量的合并上屏：增量先攒起来，过 `interval` 后一次性交给 `onFlush`，
/// 避免每个 token 都触发一次重新排版（Quick AI 回答与划词翻译共用）。
@MainActor
final class StreamingTextBuffer {
    private let interval: Duration
    private let onFlush: (String) -> Void
    private var pending = ""
    private var flushTask: Task<Void, Never>?

    init(interval: Duration, onFlush: @escaping (String) -> Void) {
        self.interval = interval
        self.onFlush = onFlush
    }

    isolated deinit {
        flushTask?.cancel()
    }

    /// 攒下一段增量；已有待上屏的批次时并入其中，否则在 `interval` 后上屏。
    func append(_ text: String) {
        pending += text
        guard flushTask == nil else { return }
        let interval = self.interval
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// 立即交出已攒下的增量（定时到达、完成、失败或中断时）。
    func flush() {
        flushTask?.cancel()
        flushTask = nil
        guard !pending.isEmpty else { return }
        let text = pending
        pending = ""
        onFlush(text)
    }

    /// 丢弃尚未上屏的增量。
    func discard() {
        flushTask?.cancel()
        flushTask = nil
        pending = ""
    }
}
