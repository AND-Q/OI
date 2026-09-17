import AppKit
import SwiftUI

/// 启动器面板原生液态玻璃表面（Liquid Glass Surface）
///
/// 采用 macOS 原生 `NSGlassEffectView`，移除过度遮盖的实色漫反射层，
/// 还原真实物理折射与通透磨砂质感：
/// - 浅色模式下：底层 Liquid Glass 的边缘高光与环境色自然透射，呈现通透灵动的微晶玻璃；
/// - 深色模式下：精准联动 `darkAqua` 外观，呈现深邃、通透、低亮度的深黑磨砂质感，完全对标原生 Spotlight。
extension View {
    @ViewBuilder
    func launcherPanelSurface(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        self
            .background {
                LiquidGlassBackground(cornerRadius: cornerRadius)
            }
            .clipShape(shape)
            .overlay {
                PanelBorder(cornerRadius: cornerRadius)
            }
    }
}

/// 0.5pt 边缘微晶高光描边，模拟原生 Spotlight 物理玻璃边缘反光。
private struct PanelBorder: View {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape.strokeBorder(
            colorScheme == .dark
                ? Color.white.opacity(0.18)
                : Color.white.opacity(0.45),
            lineWidth: 0.5
        )
    }
}

/// AppKit `NSGlassEffectView` 原生液态玻璃材质桥接视图。
/// 动态感知并实时同步宿主环境外观，确保浅色与暗黑模式均呈现原生级质感。
struct LiquidGlassBackground: NSViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
    }

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .regular
        view.cornerRadius = cornerRadius
        updateAppearance(for: view)
        return view
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
        if nsView.cornerRadius != cornerRadius {
            nsView.cornerRadius = cornerRadius
        }
        updateAppearance(for: nsView)
    }

    private func updateAppearance(for view: NSGlassEffectView) {
        let isDark = colorScheme == .dark
            || (view.window?.effectiveAppearance.isDarkMode ?? NSApp.effectiveAppearance.isDarkMode)
        let targetAppearance = isDark ? NSAppearance(named: .darkAqua) : NSAppearance(named: .aqua)
        if view.appearance != targetAppearance {
            view.appearance = targetAppearance
        }
    }
}

private extension NSAppearance {
    var isDarkMode: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

typealias VisualEffectBackground = LiquidGlassBackground
