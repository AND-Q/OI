import AppKit

/// Presentation-layer service for obtaining an application's icon.
@MainActor
protocol ApplicationIconProviding {
    func icon(for url: URL) -> NSImage
}
