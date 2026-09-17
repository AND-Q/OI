import AppKit
import SwiftUI

/// 启动器面板液态玻璃外壳表面（带 186 亮度保底）
///
/// 结合 macOS 26 原生 `NSGlassEffectView` 与高反射漫反射散射层：
/// - 在浅色背景（如 Google）下：底层 Liquid Glass 的边缘高光与环境色自然折射，保持晶莹通透；
/// - 在深色背景（如暗黑应用）下：通过精确校准的漫反射白托将最低亮度稳固保持在 186 左右，
///   防止面板因完全透光而发黑变脏，确保深色文字锐利清晰（完全对标官方 Spotlight 实测像素值）。
extension View {
    @ViewBuilder
    func launcherPanelSurface(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        self
            .background {
                ZStack {
                    // 1. 底层：macOS 26 原生 Liquid Glass 材质
                    LiquidGlassBackground(cornerRadius: cornerRadius)
                    // 2. 中层：186 亮度保底漫反射层
                    PanelInnerWash()
                }
            }
            .clipShape(shape)
            .overlay {
                // 3. 顶层：0.5pt 边缘微晶折射描边
                PanelBorder(cornerRadius: cornerRadius)
            }
    }
}

/// 漫反射保底层：
/// 浅色模式下提供约 78% 的高散射白托，经光学计算确保即使在亮度仅 22 的深色背景上，
/// 整体合成亮度也不会跌破 186；深色模式下提供石墨质感。
private struct PanelInnerWash: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if colorScheme == .dark {
            Color.black.opacity(0.35)
        } else {
            Color(white: 0.97).opacity(0.78)
        }
    }
}

/// 0.5pt 边缘微晶高光描边，模拟物理玻璃边缘 Specular 反光。
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

/// AppKit `NSGlassEffectView` 原生液态玻璃材质桥接视图。
struct LiquidGlassBackground: NSViewRepresentable {
    let cornerRadius: CGFloat

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
    }

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .regular
        view.cornerRadius = cornerRadius
        return view
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
        if nsView.cornerRadius != cornerRadius {
            nsView.cornerRadius = cornerRadius
        }
    }
}

typealias VisualEffectBackground = LiquidGlassBackground
