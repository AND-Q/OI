import AppKit
import Foundation
import XCTest

@testable import OI

@MainActor
final class PanelAnimationCoordinatorTests: XCTestCase {
    func testPanelAnimationCoordinatorComputesExpectedSpotlightFrame() {
        let screen = NSScreen.main
        let frame = PanelAnimationCoordinator.frame(for: screen, height: LauncherLayout.searchHeight)
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        XCTAssertEqual(frame.width, LauncherLayout.width)
        XCTAssertEqual(frame.height, LauncherLayout.searchHeight)
        XCTAssertEqual(frame.midX, visibleFrame.midX, accuracy: 1.0)
        XCTAssertEqual(frame.maxY, (visibleFrame.maxY - 156).rounded(), accuracy: 1.0)
        XCTAssertGreaterThanOrEqual(frame.minY, visibleFrame.minY)
        XCTAssertLessThanOrEqual(frame.maxY, visibleFrame.maxY)
    }

    func testCompactSurfaceUsesTopViewportOfExpandedGlass() {
        let hostedContent = NSView(frame: .zero)
        let surface = LauncherPanelSurface(
            contentView: hostedContent,
            cornerRadius: LauncherLayout.compactCornerRadius
        )
        surface.frame = NSRect(
            x: 0,
            y: 0,
            width: LauncherLayout.width,
            height: LauncherLayout.searchHeight
        )
        surface.layoutSubtreeIfNeeded()

        guard let glassView = surface.subviews.first as? NSGlassEffectView,
              let contentContainer = glassView.contentView else {
            return XCTFail("Expected the launcher surface to contain a glass viewport")
        }

        let expandedHeight = LauncherLayout.totalHeight(
            isExpanded: true,
            content: .results(rowCount: LauncherLayout.maximumVisibleRows)
        )
        XCTAssertEqual(glassView.frame.height, expandedHeight)
        XCTAssertEqual(glassView.frame.maxY, surface.bounds.maxY)
        XCTAssertEqual(hostedContent.frame.size, surface.bounds.size)
        XCTAssertEqual(hostedContent.frame.maxY, contentContainer.bounds.maxY)
    }

    func testClearingQueryBeforeFirstAnimationFrameCancelsExpansion() {
        let panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: LauncherLayout.width, height: LauncherLayout.searchHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let animation = PanelAnimationCoordinator(
            panel: panel,
            initialHeight: LauncherLayout.searchHeight,
            reduceMotion: { false }
        )
        defer { animation.stopAnimations() }

        let expandedHeight = LauncherLayout.totalHeight(isExpanded: true, content: .results(rowCount: 7))
        animation.resize(toHeight: expandedHeight)
        XCTAssertEqual(animation.targetHeight, expandedHeight)
        XCTAssertEqual(animation.currentHeight, LauncherLayout.searchHeight)

        animation.resize(toHeight: LauncherLayout.searchHeight)
        XCTAssertEqual(animation.targetHeight, LauncherLayout.searchHeight)
        XCTAssertEqual(panel.frame.height, LauncherLayout.searchHeight)
    }

    func testReducedMotionResizesPanelAndGlassImmediately() {
        let panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: LauncherLayout.width, height: LauncherLayout.searchHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let surface = LauncherPanelSurface(
            contentView: NSView(frame: NSRect(origin: .zero, size: panel.frame.size)),
            cornerRadius: LauncherLayout.compactCornerRadius
        )
        panel.contentView = surface
        let animation = PanelAnimationCoordinator(
            panel: panel,
            initialHeight: LauncherLayout.searchHeight,
            reduceMotion: { true }
        )

        let expandedHeight = LauncherLayout.totalHeight(isExpanded: true, content: .results(rowCount: 7))
        animation.resize(toHeight: expandedHeight)
        XCTAssertEqual(panel.frame.height, expandedHeight)
        XCTAssertEqual(animation.currentHeight, expandedHeight)
        XCTAssertEqual(surface.cornerRadius, LauncherLayout.expandedCornerRadius)

        let topEdge = panel.frame.maxY
        animation.resize(toHeight: LauncherLayout.searchHeight)
        XCTAssertEqual(panel.frame.height, LauncherLayout.searchHeight)
        XCTAssertEqual(animation.currentHeight, LauncherLayout.searchHeight)
        XCTAssertEqual(surface.cornerRadius, LauncherLayout.compactCornerRadius)
        XCTAssertEqual(panel.frame.maxY, topEdge)

        animation.fadeIn()
        XCTAssertEqual(panel.alphaValue, 1)
        animation.fadeOutAndOrderOut()
        XCTAssertFalse(panel.isVisible)
        XCTAssertFalse(animation.isDismissalInProgress)
        XCTAssertEqual(panel.alphaValue, 1)
    }

    func testDraggedPanelKeepsTopLeftWhenResizingUntilMovedBackToDefaultPosition() throws {
        guard let screen = NSScreen.main else { throw XCTSkip("没有可用的显示器") }
        let panel = LauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: LauncherLayout.width, height: LauncherLayout.searchHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let animation = PanelAnimationCoordinator(
            panel: panel,
            initialHeight: LauncherLayout.searchHeight,
            reduceMotion: { true }
        )
        animation.screen = screen
        animation.moveToDefaultPosition(height: LauncherLayout.searchHeight)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }

        // 用户拖动：不经协调者移动面板。
        let visibleFrame = screen.visibleFrame
        let draggedTopLeft = NSPoint(x: visibleFrame.minX + 40, y: visibleFrame.maxY - 40)
        panel.setFrameTopLeftPoint(draggedTopLeft)

        let quickAIHeight = LauncherLayout.totalHeight(isExpanded: true, content: .quickAI)
        animation.resize(toHeight: quickAIHeight)
        XCTAssertEqual(panel.frame.height, quickAIHeight)
        XCTAssertEqual(panel.frame.minX, draggedTopLeft.x)
        XCTAssertEqual(panel.frame.maxY, draggedTopLeft.y)

        // 再次呼出时回到默认位置，不记忆拖动后的位置。
        animation.moveToDefaultPosition(height: quickAIHeight)
        XCTAssertEqual(panel.frame, PanelAnimationCoordinator.frame(for: screen, height: quickAIHeight))
    }

    func testScreenClosedBoundaryCheckIncludesScreenMaxBoundaries() {
        let screenRect = NSRect(x: 0, y: 0, width: 1470, height: 956)
        let topEdgePoint = NSPoint(x: 500, y: 956)
        let rightEdgePoint = NSPoint(x: 1470, y: 500)

        // NSRect.contains 按半开区间判断，落在最大边界上的点会判为不包含
        XCTAssertFalse(screenRect.contains(topEdgePoint))
        XCTAssertFalse(screenRect.contains(rightEdgePoint))

        // 按闭区间判断才能包含四条边
        let containsPoint: (NSRect, NSPoint) -> Bool = { frame, point in
            point.x >= frame.minX && point.x <= frame.maxX
                && point.y >= frame.minY && point.y <= frame.maxY
        }
        XCTAssertTrue(containsPoint(screenRect, topEdgePoint))
        XCTAssertTrue(containsPoint(screenRect, rightEdgePoint))
        XCTAssertTrue(containsPoint(screenRect, NSPoint(x: 0, y: 500)))
        XCTAssertTrue(containsPoint(screenRect, NSPoint(x: 500, y: 0)))
        XCTAssertFalse(containsPoint(screenRect, NSPoint(x: 500, y: 956.1)))
        XCTAssertFalse(containsPoint(screenRect, NSPoint(x: 1470.1, y: 500)))
    }
}
