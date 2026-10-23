import AVFoundation

/// 发音朗读：用 `AVSpeechSynthesizer` 在本机合成语音，不联网；按原文语言选用本机已安装的发音人。
/// 所有气泡共用一个实例，同一时间只朗读一段。
@MainActor
final class SystemTextSpeaker: NSObject, TextSpeaking {
    private let synthesizer = AVSpeechSynthesizer()
    /// 正在朗读的一段：标识用于核对代理回调属于哪一段，续体在读完或停止时恢复，让 `speak` 返回。
    private var current: (id: ObjectIdentifier, continuation: CheckedContinuation<Void, Never>)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, languageCode: String?) async {
        if let current {
            finish(current.id)
        }
        guard !Task.isCancelled else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.voice(for: languageCode)
        let id = ObjectIdentifier(utterance)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                current = (id, continuation)
                synthesizer.speak(utterance)
            }
        } onCancel: {
            Task { @MainActor in self.finish(id) }
        }
    }

    /// 原文语言的发音人：优先该语言最常用地区的（英语为美国、简体中文为中国大陆、繁体中文为台湾），没有时取同一语言
    /// 其他地区的；同一地区内音质最好的优先（高级、增强、默认依次），不用趣味声音与个人声音。
    /// 语言为 nil 或本机没有该语言的发音人时为 nil，由系统默认的发音人朗读。
    static func voice(for languageCode: String?) -> AVSpeechSynthesisVoice? {
        guard let languageCode else { return nil }
        let language = Locale.Language(identifier: Locale.Language(identifier: languageCode).maximalIdentifier)
        guard let code = language.languageCode else { return nil }
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            Locale.Language(identifier: voice.language).languageCode == code
                && voice.voiceTraits.isDisjoint(with: [.isNoveltyVoice, .isPersonalVoice])
        }
        let rank = { (voice: AVSpeechSynthesisVoice) in
            (Locale.Language(identifier: voice.language).region == language.region ? 1 : 0, voice.quality.rawValue)
        }
        return candidates.max { rank($0) < rank($1) }
    }

    /// 停止 `id` 这一段的朗读并让等待中的 `speak` 返回；已读完或已被取代时什么也不做。
    private func finish(_ id: ObjectIdentifier) {
        guard let current, current.id == id else { return }
        self.current = nil
        synthesizer.stopSpeaking(at: .immediate)
        current.continuation.resume()
    }

    /// 代理回调到达时可能已开始朗读新的一段（旧语句释放后标识可能被复用）：仍在发音就不是这一段读完了。
    private func didEnd(_ id: ObjectIdentifier) {
        guard !synthesizer.isSpeaking else { return }
        finish(id)
    }
}

extension SystemTextSpeaker: AVSpeechSynthesizerDelegate {
    // 系统没有说明代理在哪个线程回调，回到主线程再处理。
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.didEnd(id) }
    }

    /// 被系统中断（如音频设备变化）时同样结束；OI 自己停止的那一段已在 `finish` 中处理过。
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.didEnd(id) }
    }
}
