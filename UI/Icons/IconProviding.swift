import AppKit

/// Presentation-layer service for obtaining the icon of an application or file.
@MainActor
protocol IconProviding {
    func icon(for url: URL) -> NSImage
}
