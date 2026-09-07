import AppKit
import SwiftUI

/// The launcher panel surface: native frosted vibrancy material (`NSVisualEffectView`)
/// paired with an appearance-matched wash and subtle highlight stroke, mirroring
/// native Spotlight across both light and dark backgrounds.
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

/// Base wash that prevents dark backdrops (e.g. Terminal) from washing out the
/// panel in light mode, while providing rich graphite depth in dark mode.
private struct PanelInnerWash: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if colorScheme == .dark {
            Color.black.opacity(0.35)
        } else {
            // High-opacity white wash keeps the capsule clean and crisp even over dark windows
            Color.white.opacity(0.85)
        }
    }
}

/// Subtle hairline stroke: 0.5pt specular border in dark mode (matching native
/// Spotlight), soft neutral stroke in light mode.
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

/// AppKit `NSVisualEffectView` bridge for native macOS vibrancy.
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
