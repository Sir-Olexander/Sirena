import XCTest
@testable import SirenaCore

/// The pill keeps its bottom edge where it was put, whatever its size, wherever the Dock is.
final class OverlayPlacementTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    func testBottomEdgeStaysPutWhenThePillResizes() {
        // Placed 10 pt above the bottom of the screen, i.e. where the Dock is when it shows.
        let anchor = CGPoint(x: 1167.5, y: 10)
        let compact = OverlayPanel.placement(size: CGSize(width: 120, height: 34), anchor: anchor, screen: screen)
        let expanded = OverlayPanel.placement(size: CGSize(width: 330, height: 52), anchor: anchor, screen: screen)
        XCTAssertEqual(compact.minY, 10)
        XCTAssertEqual(expanded.minY, 10)
        XCTAssertEqual(compact.midX, expanded.midX)
    }

    func testStaysInsideTheScreen() {
        let nearRight = OverlayPanel.placement(size: CGSize(width: 400, height: 50), anchor: CGPoint(x: 1400, y: -30), screen: screen)
        XCTAssertEqual(nearRight.maxX, 1440)
        XCTAssertEqual(nearRight.minY, 0)
        // A second monitor to the right.
        let external = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let there = OverlayPanel.placement(size: CGSize(width: 200, height: 40), anchor: CGPoint(x: 2400, y: 1070), screen: external)
        XCTAssertEqual(there.maxY, 1080)
        XCTAssertEqual(there.midX, 2400)
    }
}
