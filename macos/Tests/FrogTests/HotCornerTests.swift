import AppKit
import XCTest
@testable import Frog

@MainActor
private final class FakeHotCornerMonitor: HotCornerEventMonitoring {
    var screens = [HotCornerScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))]
    var mouseLocation = CGPoint(x: 50, y: 50)
    var suspended = false
    var sample: ((CGPoint, Bool) -> Void)?
    var reset: (() -> Void)?
    var starts = 0
    var fails = false
    func start(sample: @escaping (CGPoint, Bool) -> Void, reset: @escaping () -> Void) throws {
        starts += 1
        self.sample = sample; self.reset = reset
        if fails { throw NSError(domain: "HotCornerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "监听失败"]) }
    }
    func stop() { sample = nil; reset = nil }
    func move(_ x: CGFloat, _ y: CGFloat, down: Bool = false) {
        mouseLocation = CGPoint(x: x, y: y)
        sample?(mouseLocation, down)
    }
}

@MainActor
final class HotCornerTests: XCTestCase {
    private let screen = HotCornerScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100))

    func testFourCornersAndTwoPointBoundary() {
        let points: [(ScreenCorner, CGPoint, CGPoint, CGPoint)] = [
            (.bottomLeft, .zero, CGPoint(x: 2, y: 2), CGPoint(x: 2.01, y: 2)),
            (.topLeft, CGPoint(x: 0, y: 100), CGPoint(x: 2, y: 98), CGPoint(x: 2, y: 97.99)),
            (.topRight, CGPoint(x: 100, y: 100), CGPoint(x: 98, y: 98), CGPoint(x: 97.99, y: 98)),
            (.bottomRight, CGPoint(x: 100, y: 0), CGPoint(x: 98, y: 2), CGPoint(x: 98, y: 2.01))
        ]
        for (corner, edge, inside, outside) in points {
            XCTAssertTrue(corner.contains(edge, in: screen.frame, size: 2))
            XCTAssertTrue(corner.contains(inside, in: screen.frame, size: 2))
            XCTAssertFalse(corner.contains(outside, in: screen.frame, size: 2))
            for other in ScreenCorner.allCases where other != corner {
                XCTAssertFalse(other.contains(edge, in: screen.frame, size: 2))
            }
        }
        XCTAssertFalse(ScreenCorner.bottomLeft.contains(CGPoint(x: -0.01, y: 0), in: screen.frame, size: 2))
        XCTAssertFalse(ScreenCorner.topRight.contains(CGPoint(x: 100.01, y: 100), in: screen.frame, size: 2))
        XCTAssertFalse(ScreenCorner.bottomLeft.contains(.zero, in: .zero, size: 2))
    }

    func testNegativeCoordinatesAndTargetScreen() {
        let left = HotCornerScreen(id: 2, frame: CGRect(x: -200, y: -50, width: 200, height: 150))
        var detector = HotCornerDetector()
        XCTAssertEqual(detector.update(at: CGPoint(x: -199, y: -49), screens: [screen, left], corner: .bottomLeft,
                                       eligible: true, mouseButtonDown: false), left)
        XCTAssertEqual(detector.update(at: CGPoint(x: 1, y: 1), screens: [screen, left], corner: .bottomLeft,
                                       eligible: true, mouseButtonDown: false), screen)
        XCTAssertNil(detector.update(at: CGPoint(x: -201, y: -50), screens: [screen, left], corner: .bottomLeft,
                                     eligible: true, mouseButtonDown: false))
        XCTAssertTrue(ScreenCorner.topRight.contains(CGPoint(x: -1, y: 99), in: left.frame, size: 2))
    }

    func testStayingAndJitterWithinEightPointsDoesNotRetrigger() {
        var detector = HotCornerDetector()
        func enter(_ x: CGFloat, _ y: CGFloat) -> HotCornerScreen? {
            detector.update(at: CGPoint(x: x, y: y), screens: [screen], corner: .bottomLeft,
                            eligible: true, mouseButtonDown: false)
        }
        XCTAssertEqual(enter(1, 1), screen)
        for _ in 0..<100 { XCTAssertNil(enter(1, 1)) }
        XCTAssertNil(enter(8, 8)); XCTAssertNil(enter(0, 0))
        XCTAssertNil(enter(8.01, 8))
        XCTAssertEqual(enter(2, 2), screen)
        XCTAssertNil(enter(1, 8.01))
        XCTAssertEqual(enter(0, 0), screen)
    }

    func testResetAtCornerOrHysteresisAreaRequiresLeaving() {
        for position in [CGPoint.zero, CGPoint(x: 7, y: 7)] {
            var detector = HotCornerDetector()
            detector.reset(at: position, screens: [screen], corner: .bottomLeft)
            XCTAssertNil(detector.update(at: .zero, screens: [screen], corner: .bottomLeft, eligible: true, mouseButtonDown: false))
            XCTAssertNil(detector.update(at: CGPoint(x: 50, y: 50), screens: [screen], corner: .bottomLeft, eligible: true, mouseButtonDown: false))
            XCTAssertEqual(detector.update(at: .zero, screens: [screen], corner: .bottomLeft, eligible: true, mouseButtonDown: false), screen)
        }
    }

    func testSuppressedAndDraggedEntryMustLeaveBeforeTriggering() {
        for (eligible, down) in [(false, false), (true, true), (false, true)] {
            var detector = HotCornerDetector()
            XCTAssertNil(detector.update(at: .zero, screens: [screen], corner: .bottomLeft, eligible: eligible, mouseButtonDown: down))
            XCTAssertNil(detector.update(at: .zero, screens: [screen], corner: .bottomLeft, eligible: true, mouseButtonDown: false))
            XCTAssertNil(detector.update(at: CGPoint(x: 9, y: 0), screens: [screen], corner: .bottomLeft, eligible: true, mouseButtonDown: false))
            XCTAssertEqual(detector.update(at: .zero, screens: [screen], corner: .bottomLeft, eligible: true, mouseButtonDown: false), screen)
        }
    }

    func testDefaultStartsOnceAndStopsAllCallbacks() {
        let source = FakeHotCornerMonitor()
        let controller = HotCornerController(source: source, defaults: nil)
        var triggers = 0
        controller.canTrigger = { true }; controller.onTrigger = { _ in triggers += 1 }
        XCTAssertEqual(controller.configuration, HotCornerConfiguration())
        XCTAssertTrue(controller.configuration.enabled)
        XCTAssertEqual(controller.configuration.corner, .bottomLeft)
        XCTAssertNil(source.sample)
        controller.start(); controller.start()
        XCTAssertTrue(controller.monitoring); XCTAssertEqual(source.starts, 1)
        source.move(0, 0)
        XCTAssertEqual(triggers, 1)
        let old = source.sample
        controller.stop()
        old?(CGPoint(x: 50, y: 50), false); old?(.zero, false)
        XCTAssertEqual(triggers, 1); XCTAssertFalse(controller.monitoring)
        XCTAssertNil(source.sample); XCTAssertNil(source.reset)
    }

    func testEnabledAndCornerSurviveRestart() throws {
        let name = "Frog-HotCorner-Tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = HotCornerController(source: FakeHotCornerMonitor(), defaults: defaults)
        controller.start(); controller.setCorner(.topRight); controller.setEnabled(false); controller.stop()
        let source = FakeHotCornerMonitor()
        let restarted = HotCornerController(source: source, defaults: defaults)
        restarted.start()
        XCTAssertEqual(restarted.configuration, HotCornerConfiguration(enabled: false, corner: .topRight))
        XCTAssertFalse(restarted.monitoring); XCTAssertEqual(source.starts, 0)
        restarted.setEnabled(true)
        XCTAssertTrue(restarted.monitoring); XCTAssertEqual(source.starts, 1)
        restarted.stop()
        XCTAssertEqual(HotCornerController(source: FakeHotCornerMonitor(), defaults: defaults).configuration,
                       HotCornerConfiguration(enabled: true, corner: .topRight))
    }

    func testIsolatedSettingsNeverWriteStandardPreferences() {
        let before = UserDefaults.standard.data(forKey: HotCornerController.preferencesKey)
        let controller = HotCornerController(source: FakeHotCornerMonitor(), defaults: nil)
        controller.start(); controller.setCorner(.bottomRight); controller.setEnabled(false); controller.stop()
        XCTAssertEqual(UserDefaults.standard.data(forKey: HotCornerController.preferencesKey), before)
        XCTAssertEqual(HotCornerController(source: FakeHotCornerMonitor(), defaults: nil).configuration, HotCornerConfiguration())
    }

    func testInvalidSavedConfigurationFallsBackToDefault() throws {
        let name = "Frog-HotCorner-Tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("{\"enabled\":true,\"corner\":\"unknown\"}".utf8), forKey: HotCornerController.preferencesKey)
        XCTAssertEqual(HotCornerController(source: FakeHotCornerMonitor(), defaults: defaults).configuration, HotCornerConfiguration())
    }

    func testEnableAndCornerChangeAtPointerDoNotOpenInPlace() {
        let source = FakeHotCornerMonitor()
        source.mouseLocation = .zero
        let controller = HotCornerController(source: source, defaults: nil)
        var triggers = 0
        controller.canTrigger = { true }; controller.onTrigger = { _ in triggers += 1 }
        controller.start(); source.move(0, 0)
        XCTAssertEqual(triggers, 0)
        controller.setEnabled(false); controller.setEnabled(true); source.move(0, 0)
        XCTAssertEqual(triggers, 0)
        source.move(100, 100); controller.setCorner(.topRight); source.move(100, 100)
        XCTAssertEqual(triggers, 0)
        source.move(50, 50); source.move(100, 100)
        XCTAssertEqual(triggers, 1)
        source.move(0, 0)
        XCTAssertEqual(triggers, 1, "原角落不再触发")
        controller.stop()
    }

    func testOldMonitorCannotTriggerAfterReconfiguration() {
        let source = FakeHotCornerMonitor()
        let controller = HotCornerController(source: source, defaults: nil)
        var triggers = 0
        controller.canTrigger = { true }; controller.onTrigger = { _ in triggers += 1 }
        controller.start()
        let oldSample = source.sample, oldReset = source.reset
        controller.setEnabled(false); oldSample?(.zero, false)
        controller.setEnabled(true); oldSample?(.zero, false)
        XCTAssertEqual(triggers, 0)
        source.mouseLocation = .zero; oldReset?()
        source.move(0, 0)
        XCTAssertEqual(triggers, 1, "旧重置回调不能改变新监听的进入状态")
        controller.stop()
    }

    func testMonitorFailureCleansUpAndRetryRecovers() {
        let source = FakeHotCornerMonitor(); source.fails = true
        let controller = HotCornerController(source: source, defaults: nil)
        controller.start()
        XCTAssertFalse(controller.monitoring); XCTAssertEqual(controller.error, "监听失败")
        XCTAssertNil(source.sample); XCTAssertNil(source.reset)
        source.fails = false; controller.retry()
        XCTAssertTrue(controller.monitoring); XCTAssertNil(controller.error)
        controller.stop()
        controller.retry()
        XCTAssertFalse(controller.monitoring); XCTAssertNil(source.sample)
    }

    func testDisplayChangeResetsPositionAndUsesNewScreen() {
        let source = FakeHotCornerMonitor()
        let controller = HotCornerController(source: source, defaults: nil)
        var triggered: [UInt32] = []
        controller.canTrigger = { true }; controller.onTrigger = { triggered.append($0.id) }
        controller.start(); source.move(0, 0)
        let newScreen = HotCornerScreen(id: 2, frame: CGRect(x: -100, y: -100, width: 100, height: 100))
        source.screens = [newScreen]; source.mouseLocation = CGPoint(x: -100, y: -100); source.reset?()
        source.move(-100, -100)
        XCTAssertEqual(triggered, [1])
        source.move(-50, -50); source.move(-100, -100)
        XCTAssertEqual(triggered, [1, 2])
        source.move(0, 0)
        XCTAssertEqual(triggered, [1, 2])
        controller.stop()
    }

    func testSuspendAndResumeAtCornerRequireReentry() {
        let source = FakeHotCornerMonitor()
        let controller = HotCornerController(source: source, defaults: nil)
        var triggers = 0
        controller.canTrigger = { true }; controller.onTrigger = { _ in triggers += 1 }
        controller.start()
        source.suspended = true; source.reset?(); source.move(0, 0)
        XCTAssertEqual(triggers, 0)
        source.suspended = false; source.reset?(); source.move(0, 0)
        XCTAssertEqual(triggers, 0)
        source.move(50, 50); source.move(0, 0)
        XCTAssertEqual(triggers, 1)
        controller.stop()
    }

    func testWindowAndSystemPanelSuppressionCannotOpenAfterHidingInPlace() {
        let source = FakeHotCornerMonitor()
        let controller = HotCornerController(source: source, defaults: nil)
        var visible = true, presented = true, panel = false, triggers = 0
        controller.canTrigger = { LauncherActivationState.allowsCorner(visible: visible, presented: presented, systemPanelActive: panel) }
        controller.onTrigger = { _ in triggers += 1 }
        controller.start(); source.move(0, 0)
        presented = false; source.move(50, 50); source.move(0, 0)
        visible = false; source.move(0, 0)
        XCTAssertEqual(triggers, 0)
        panel = true; source.move(50, 50); source.move(0, 0)
        panel = false; source.move(0, 0)
        XCTAssertEqual(triggers, 0)
        source.move(50, 50); source.move(0, 0)
        XCTAssertEqual(triggers, 1)
        XCTAssertFalse(LauncherActivationState.allowsCorner(visible: false, presented: true, systemPanelActive: false))
        controller.stop()
    }

    func testLoadingRetainsOpenRequestWithoutTogglingItOff() {
        var activation = LauncherActivationState()
        XCTAssertFalse(activation.requestShow()); XCTAssertFalse(activation.requestShow())
        XCTAssertFalse(activation.loaded)
        XCTAssertTrue(activation.finishLoading(silently: true))
        XCTAssertTrue(activation.requestShow())
        XCTAssertFalse(activation.finishLoading(silently: true), "已消费的请求不残留")
        var silent = LauncherActivationState()
        XCTAssertFalse(silent.finishLoading(silently: true))
    }
}
