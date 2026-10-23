import AppKit

/// 表现层的图标服务：取应用或文件的图标。
@MainActor
protocol IconProviding {
    func icon(for url: URL) -> NSImage
}
