import AppKit
import SwiftUI

/// The launcher panel surface: system Liquid Glass via SwiftUI `glassEffect`
/// on macOS 26+ — the only rendering path whose window shadow follows the
/// capsule shape when the panel is key — and a frosted material below that.
extension View {
    @ViewBuilder
    func launcherPanelSurface(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            ZStack {
                // glassEffect inserts itself in front of content *backgrounds*,
                // so a `.background` wash would hide under the glass body. As
                // content, the wash drives the glass's brightness sampling:
                // the capsule stays frosted-light in light appearance on any
                // backdrop, matching native Spotlight. The wash must be a
                // static color resolved before rendering — the glass sampler
                // cannot read dynamic NSColors (proven by A/B).
                PanelInnerWash()
                self
            }
            .clipShape(shape)
            .glassEffect(.regular, in: shape)
        } else {
            self
                .background(VisualEffectBackground(cornerRadius: cornerRadius))
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                }
        }
    }
}

/// Light wash inside the glass. Resolved per color scheme at view build time
/// so the glassEffect sampler sees a static color.
@available(macOS 26.0, *)
private struct PanelInnerWash: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        colorScheme == .dark ? Color.black.opacity(0.25) : Color.white.opacity(0.35)
    }
}

/// Legacy frosted material for systems without Liquid Glass.
struct VisualEffectBackground: NSViewRepresentable {
    let cornerRadius: CGFloat

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSVisualEffectView()
        view.material = .titlebar
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        view.wantsLayer = true
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        view.layer?.cornerRadius = cornerRadius
    }
}
