import AppKit
import SwiftUI

/// AppKit `NSVisualEffectView` bridge used for the launcher panel's frosted glass.
/// `.titlebar` + behind-window blending matches native Spotlight on macOS 26
/// (near-white over bright backgrounds, frosted over wallpaper; measured against
/// full-resolution native screenshots). A small dynamic white tint adds the extra frost.
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let cornerRadius: CGFloat

    init(
        material: NSVisualEffectView.Material = .titlebar,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        cornerRadius: CGFloat = 0
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.cornerRadius = cornerRadius
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = false
        view.wantsLayer = true
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true

        let tint = FrostTintView()
        tint.autoresizingMask = [.width, .height]
        view.addSubview(tint)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
        nsView.layer?.cornerRadius = cornerRadius
    }
}

/// Thin white wash whose strength follows the system appearance.
private final class FrostTintView: NSView {
    private static let lightAlpha: CGFloat = 0.20
    private static let darkAlpha: CGFloat = 0.06
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Self.tintColor(for: effectiveAppearance).cgColor
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = Self.tintColor(for: effectiveAppearance).cgColor
    }

    private static func tintColor(for appearance: NSAppearance) -> NSColor {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor.white.withAlphaComponent(dark ? Self.darkAlpha : Self.lightAlpha)
    }
}
