import AppKit

/// 用统一的圆角轮廓约束整个玻璃表面，窗口阴影仍由系统绘制。
/// 内容放入原生玻璃的 contentView，继承窗口外观和辅助功能设置。
final class LauncherPanelSurface: NSView {
    private static let expandedGlassHeight = LauncherLayout.totalHeight(
        isExpanded: true,
        content: .results(rowCount: LauncherLayout.maximumVisibleRows)
    )

    private let glassView = NSGlassEffectView()
    private let contentContainer = NSView()
    private let hostedContentView: NSView

    var cornerRadius: CGFloat { glassView.cornerRadius }

    init(contentView: NSView, cornerRadius: CGFloat) {
        hostedContentView = contentView
        super.init(frame: contentView.frame)
        // 玻璃内部还有系统管理的效果层，只裁剪内容无法约束整个轮廓。
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        glassView.autoresizingMask = []
        glassView.style = .regular

        contentContainer.autoresizingMask = [.width, .height]
        contentView.autoresizingMask = []
        contentContainer.addSubview(contentView)
        glassView.contentView = contentContainer
        addSubview(glassView)
        updateCornerRadius(cornerRadius)
    }

    func updateCornerRadius(_ radius: CGFloat) {
        glassView.cornerRadius = radius
        layer?.cornerRadius = radius
        updateGlassViewport()
    }

    override func layout() {
        super.layout()
        updateGlassViewport()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        updateGlassViewport()
    }

    /// 始终以展开后的玻璃画布渲染；收起时只裁出顶部搜索区。
    private func updateGlassViewport() {
        guard !bounds.isEmpty else { return }

        let glassHeight = max(Self.expandedGlassHeight, bounds.height)
        glassView.frame = NSRect(
            x: bounds.minX,
            y: bounds.maxY - glassHeight,
            width: bounds.width,
            height: glassHeight
        )
        contentContainer.frame = glassView.bounds
        hostedContentView.frame = NSRect(
            x: 0,
            y: glassHeight - bounds.height,
            width: bounds.width,
            height: bounds.height
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
