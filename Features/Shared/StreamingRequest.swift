import Foundation

/// 一次流式请求（Quick AI 回答、划词翻译）的运行与中断：增量经 `StreamingTextBuffer` 合并上屏；
/// 新的请求或中断会取代进行中的请求，此后它到达的增量、结果与错误一律丢弃（按 generation 判断）。
@MainActor
final class StreamingRequest {
    private let buffer: StreamingTextBuffer
    private var task: Task<Void, Never>?
    private var generation = 0

    /// `onText` 每隔 `flushInterval` 收到一批合并后的增量。
    init(flushInterval: Duration, onText: @escaping (String) -> Void) {
        buffer = StreamingTextBuffer(interval: flushInterval, onFlush: onText)
    }

    isolated deinit {
        task?.cancel()
    }

    /// 开始请求并取代进行中的请求。`operation` 把增量逐段交给传入的回调；结束时先交出攒下的增量，
    /// 再以 nil（完成）或错误调用 `onCompletion`。被取代或中断的请求不再调用 `onCompletion`。
    @discardableResult
    func start(
        _ operation: @escaping @MainActor (_ onDelta: (String) -> Void) async throws -> Void,
        onCompletion: @escaping @MainActor (Error?) -> Void
    ) -> Task<Void, Never> {
        stop()
        buffer.discard()
        generation += 1
        let generation = self.generation
        let task = Task { [weak self] in
            var failure: Error?
            do {
                try await operation { delta in
                    guard let self, self.generation == generation else { return }
                    self.buffer.append(delta)
                }
            } catch {
                failure = error
            }
            // 中断（新的请求、取消）会递增 generation，取消带来的错误在此丢弃。
            guard let self, self.generation == generation else { return }
            self.task = nil
            self.buffer.flush()
            onCompletion(failure)
        }
        self.task = task
        return task
    }

    /// 中断进行中的请求，交出已攒下的增量；没有进行中的请求时什么也不做并返回 false。
    @discardableResult
    func stop() -> Bool {
        guard let task else { return false }
        generation += 1
        task.cancel()
        self.task = nil
        buffer.flush()
        return true
    }

    /// 丢弃尚未上屏的增量。
    func discard() {
        buffer.discard()
    }
}
