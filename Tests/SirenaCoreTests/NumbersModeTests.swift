import XCTest
@testable import SirenaCore

/// "Show numbers" with two monitors: each badge goes to the window of the screen its element is on.
final class NumbersModeTests: XCTestCase {
    // Quartz frames: built-in 1512×982 as the primary screen, a 1920×1080 monitor to its right, raised by 98 pt.
    let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let external = CGRect(x: 1512, y: -98, width: 1920, height: 1080)

    func testBadgesGoToTheScreenOfTheirElement() {
        let frames = [
            CGRect(x: 100, y: 100, width: 80, height: 20),     // on the built-in screen
            CGRect(x: 2000, y: 50, width: 80, height: 20),     // on the external screen
            CGRect(x: 1500, y: 300, width: 100, height: 20),   // straddles: top-left corner on the built-in
            CGRect(x: 1600, y: -60, width: 50, height: 20),    // above the built-in's top, inside the external
        ]
        XCTAssertEqual(NumbersMode.screenIndex(for: frames, screens: [builtIn, external]), [0, 1, 0, 1])
    }

    func testOffScreenElementsFallBackToOverlapOrNearest() {
        let frames = [
            CGRect(x: -40, y: 200, width: 100, height: 20),    // starts left of every screen, overlaps the built-in
            CGRect(x: 5000, y: 200, width: 40, height: 20),    // far right of everything: nearest is the external
        ]
        XCTAssertEqual(NumbersMode.screenIndex(for: frames, screens: [builtIn, external]), [0, 1])
        XCTAssertEqual(NumbersMode.screenIndex(for: frames, screens: []), [-1, -1])
    }

    func testCoordinatesAreLocalToEachScreenWindow() {
        let primaryHeight: CGFloat = 982
        // External screen in AppKit coordinates: origin (1512, 982 - (-98) - 1080) = (1512, 0).
        let externalAppKit = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(NumbersMode.quartz(externalAppKit, primaryHeight: primaryHeight), external)
        let local = NumbersMode.toAppKit(CGRect(x: 2000, y: 50, width: 80, height: 20), windowOrigin: externalAppKit.origin, primaryHeight: primaryHeight)
        XCTAssertEqual(local, CGRect(x: 488, y: 912, width: 80, height: 20))
    }
}
