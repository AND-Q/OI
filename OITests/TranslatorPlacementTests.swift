import AppKit
import AVFoundation
import Foundation
import XCTest

@testable import OI

/// 翻译气泡相对原文的摆放与坐标换算。
@MainActor
final class TranslatorPlacementTests: TranslatorTestCase {
    // MARK: - 气泡摆放

    func testPlacementPrefersBelowAnchorAndGrowsDownward() {
        let placement = TranslatorPlacement(
            anchor: NSRect(x: 200, y: 600, width: 80, height: 18),
            pointer: NSPoint(x: 220, y: 609),
            visibleFrame: Self.visibleFrame,
            width: 380,
            expectedHeight: 420
        )

        XCTAssertEqual(placement.edge, .below(top: 594))
        XCTAssertEqual(placement.frame(height: 150), NSRect(x: 200, y: 444, width: 380, height: 150))
        XCTAssertEqual(placement.frame(height: 300), NSRect(x: 200, y: 294, width: 380, height: 300))
    }

    func testPlacementFlipsAboveNearScreenBottomAndGrowsUpward() {
        let placement = TranslatorPlacement(
            anchor: NSRect(x: 200, y: 100, width: 80, height: 18),
            pointer: NSPoint(x: 220, y: 109),
            visibleFrame: Self.visibleFrame,
            width: 380,
            expectedHeight: 420
        )

        XCTAssertEqual(placement.edge, .above(bottom: 124))
        XCTAssertEqual(placement.frame(height: 150), NSRect(x: 200, y: 124, width: 380, height: 150))
        XCTAssertEqual(placement.frame(height: 300), NSRect(x: 200, y: 124, width: 380, height: 300))
    }

    func testPlacementStaysInsideScreenHorizontally() {
        let placement = TranslatorPlacement(
            anchor: NSRect(x: 1400, y: 600, width: 30, height: 18),
            pointer: NSPoint(x: 1410, y: 609),
            visibleFrame: Self.visibleFrame,
            width: 380,
            expectedHeight: 420
        )

        XCTAssertEqual(placement.x, 1440 - 8 - 380)
    }

    /// 跨大半屏的长选区上下都放不下时，改为贴着指针弹出，而不是压在选区中间。
    func testTallAnchorFallsBackToPointer() {
        let placement = TranslatorPlacement(
            anchor: NSRect(x: 100, y: 50, width: 600, height: 800),
            pointer: NSPoint(x: 300, y: 500),
            visibleFrame: Self.visibleFrame,
            width: 380,
            expectedHeight: 420
        )

        XCTAssertEqual(placement.edge, .below(top: 484))
        XCTAssertEqual(placement.x, 276)
    }

    /// 拖动过的气泡左上角留在放下的位置，译文增长时向下伸长，到屏幕底部后整体上移、不超出屏幕。
    func testDetachedPlacementKeepsTopLeftAndGrowsDownward() {
        let placement = TranslatorPlacement(
            keepingTopLeftOf: NSRect(x: 900, y: 500, width: 380, height: 120),
            visibleFrame: Self.visibleFrame
        )

        XCTAssertEqual(placement.frame(height: 120), NSRect(x: 900, y: 500, width: 380, height: 120))
        XCTAssertEqual(placement.frame(height: 300), NSRect(x: 900, y: 320, width: 380, height: 300))
        XCTAssertEqual(placement.frame(height: 700), NSRect(x: 900, y: 8, width: 380, height: 700))
    }

    func testGlobalCoordinatesConvertToAppKit() {
        XCTAssertEqual(
            TranslatorPlacement.appKitRect(fromGlobal: CGRect(x: 10, y: 100, width: 50, height: 20), primaryScreenHeight: 900),
            NSRect(x: 10, y: 780, width: 50, height: 20)
        )
        XCTAssertEqual(
            TranslatorPlacement.appKitPoint(fromGlobal: CGPoint(x: 10, y: 100), primaryScreenHeight: 900),
            NSPoint(x: 10, y: 800)
        )
    }
}
