import AppKit

/// 用统一的圆角轮廓约束整个玻璃表面，窗口阴影仍由系统绘制。
/// 内容放入原生玻璃的 contentView，继承窗口外观和辅助功能设置。
final class LauncherPanelSurface: NSView {
    private let glassView = NSGlassEffectView()

    var cornerRadius: CGFloat { glassView.cornerRadius }

    init(contentView: NSView, cornerRadius: CGFloat) {
        super.init(frame: contentView.frame)
        // 玻璃内部还有系统管理的效果层，只裁剪内容无法约束整个轮廓。
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        glassView.frame = bounds
        glassView.autoresizingMask = [.width, .height]
        glassView.style = .regular
        glassView.contentView = contentView
        addSubview(glassView)
        updateCornerRadius(cornerRadius)
    }

    func updateCornerRadius(_ radius: CGFloat) {
        glassView.cornerRadius = radius
        layer?.cornerRadius = radius
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
