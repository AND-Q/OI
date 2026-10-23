import Foundation

/// 监听应用目录，把变动作为「需要刷新」的信号报告出去；自身从不重建快照（搜索计划 §10.1）。
final class AppDirectoryWatcher: @unchecked Sendable {
    private let sources: [DispatchSourceFileSystemObject]

    init(directories: [URL], onChange: @escaping @Sendable () -> Void) {
        // 所有目录的源共用一个串行队列，避免为每个目录单独创建队列。
        let queue = DispatchQueue(label: "OI.AppDirectoryWatcher", qos: .utility)
        var sources: [DispatchSourceFileSystemObject] = []
        for directory in directories {
            let fileDescriptor = open(directory.path, O_EVTONLY)
            guard fileDescriptor >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fileDescriptor,
                eventMask: [.write],
                queue: queue
            )
            source.setEventHandler { onChange() }
            source.setCancelHandler { close(fileDescriptor) }
            source.resume()
            sources.append(source)
        }
        self.sources = sources
    }

    deinit {
        sources.forEach { $0.cancel() }
    }
}
