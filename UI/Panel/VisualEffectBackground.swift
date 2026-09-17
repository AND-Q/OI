import AppKit
import SwiftUI

/// The launcher panel surface, matching the native Spotlight capsule: a frosted
/// system material that keeps the *system* appearance (light stays light over a
/// dark window, with dark text) instead of adapting to the backdrop.
///
/// SwiftUI `glassEffect` is deliberately not used here: Liquid Glass flips its
/// content to the dark appearance over dark backdrops (white text), lets most of
/// the backdrop through, and draws its body above `.background`, so no platter
/// can lift it. Buttons keep the `.glass` styles; only the surface is opted out.
extension View {
    @ViewBuilder
    func launcherPanelSurface(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        self
            .background {
                ZStack {
                    VisualEffectBackground(cornerRadius: cornerRadius)
                    PanelInnerWash()
                }
            }
            .clipShape(shape)
            .overlay {
                PanelBorder(cornerRadius: cornerRadius)
            }
    }
}

/// Wash over the material, tuned against native Spotlight screenshots: it drops
/// backdrop transmission to roughly a fifth so a dark window still reads as a
/// light grey capsule, while leaving enough through for the surroundings to
/// tint it (native is ~195 grey over a dark window, ~237 over white).
private struct PanelInnerWash: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if colorScheme == .dark {
            Color.black.opacity(0.35)
        } else {
            Color(white: 0.93).opacity(0.72)
        }
    }
}

/// Hairline stroke on the capsule edge, as in native Spotlight: soft neutral
/// stroke in light mode, 0.5pt specular border in dark mode.
private struct PanelBorder: View {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape.strokeBorder(
            colorScheme == .dark
                ? Color.white.opacity(0.15)
                : Color.black.opacity(0.08),
            lineWidth: 0.5
        )
    }
}

/// AppKit `NSVisualEffectView` bridge for the frosted behind-window material.
struct VisualEffectBackground: NSViewRepresentable {
    let cornerRadius: CGFloat

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = false
        view.wantsLayer = true
        view.layer?.cornerCurve = .continuous
        view.layer?.cornerRadius = cornerRadius
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        if nsView.layer?.cornerRadius != cornerRadius {
            nsView.layer?.cornerRadius = cornerRadius
        }
    }
}
