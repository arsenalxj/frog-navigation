import AppKit
import XCTest
@testable import Frog

final class LauncherScreenPlacementTests: XCTestCase {
    private let first = LauncherDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800))
    private let second = LauncherDisplay(id: 2, frame: CGRect(x: -1200, y: 0, width: 1200, height: 900))

    func testFastReverseMovesToMouseDisplayBeforeWindowBecomesInvisible() {
        var placement = LauncherScreenPlacement()
        var activation = LauncherActivationState()
        _ = activation.finishLoading(silently: true)
        XCTAssertEqual(placement.update(visible: false, requestedID: nil, mouse: CGPoint(x: 200, y: 200),
                                        displays: [first, second], fallbackID: 1), first)
        XCTAssertEqual(activation.toggle(presented: true, applicationHidden: false, systemPanelActive: false), .hide)
        XCTAssertEqual(activation.toggle(presented: false, applicationHidden: false, systemPanelActive: false), .show)
        XCTAssertEqual(placement.update(visible: true, requestedID: nil, mouse: CGPoint(x: -200, y: 200),
                                        displays: [first, second], fallbackID: 1), second)
    }

    func testSameDisplayReverseSkipsRefreshButReopenAndGeometryChangesRefresh() {
        var placement = LauncherScreenPlacement()
        let point = CGPoint(x: 200, y: 200)
        XCTAssertEqual(placement.update(visible: false, requestedID: nil, mouse: point, displays: [first], fallbackID: 1), first)
        XCTAssertNil(placement.update(visible: true, requestedID: nil, mouse: point, displays: [first], fallbackID: 1))
        XCTAssertEqual(placement.update(visible: false, requestedID: nil, mouse: point, displays: [first], fallbackID: 1), first)
        let changed = LauncherDisplay(id: 1, frame: first.frame, visibleFrame: CGRect(x: 0, y: 60, width: 1000, height: 740))
        XCTAssertEqual(placement.update(visible: true, requestedID: nil, mouse: point, displays: [changed], fallbackID: 1), changed)
    }

    func testCornerDisplayTakesPrecedenceAndDisconnectedDisplayFallsBack() {
        var placement = LauncherScreenPlacement()
        let point = CGPoint(x: 200, y: 200)
        XCTAssertEqual(placement.update(visible: false, requestedID: 2, mouse: point, displays: [first, second], fallbackID: 1), second)
        XCTAssertEqual(placement.update(visible: true, requestedID: 2, mouse: point, displays: [first], fallbackID: 1), first)
        XCTAssertNil(placement.update(visible: false, requestedID: 2, mouse: point, displays: [], fallbackID: nil))
        XCTAssertEqual(placement.update(visible: false, requestedID: nil, mouse: CGPoint(x: 5000, y: 5000),
                                        displays: [first, second], fallbackID: 2), second)
    }
}
