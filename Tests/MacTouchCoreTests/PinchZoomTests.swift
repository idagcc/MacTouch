import CoreGraphics
import Foundation
import XCTest
@testable import MacTouchCore

final class PinchZoomTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1001, height: 1001)
    private let configuration = PointerConfiguration(mapPinchZoom: true)

    private func frame(_ x1: Double = 0.35, _ x2: Double = 0.65, y: Double = 0.5, secondID: Int = 2) -> TouchFrame {
        TouchFrame(contacts: [TouchContact(id: 1, x: x1, y: y), TouchContact(id: secondID, x: x2, y: y)])
    }

    private func zoom(_ actions: [PointerAction], file: StaticString = #filePath, line: UInt = #line) -> (Double, Double, Double)? {
        guard actions.count == 1, case let .mapZoom(x, y, delta) = actions[0] else {
            XCTFail("Expected a map zoom only, received \(actions)", file: file, line: line)
            return nil
        }
        return (x, y, delta)
    }

    func testSpreadAndPinchZoomInOppositeDirectionsAtTheMidpoint() throws {
        var engine = PointerEngine()
        _ = engine.process(frame: frame(), bounds: bounds, configuration: configuration, timestamp: 1)
        let spread = try XCTUnwrap(zoom(engine.process(frame: frame(0.30, 0.70), bounds: bounds, configuration: configuration, timestamp: 1.01)))
        XCTAssertEqual(spread.0, 500, accuracy: 0.001)
        XCTAssertEqual(spread.1, 500, accuracy: 0.001)
        XCTAssertEqual(spread.2, log(400.0 / 300) * 400, accuracy: 0.001)
        XCTAssertEqual(engine.twoFingerIntent, .pinching)
        let pinch = try XCTUnwrap(zoom(engine.process(frame: frame(0.34, 0.66), bounds: bounds, configuration: configuration, timestamp: 1.02)))
        XCTAssertLessThan(pinch.2, 0)
    }

    func testMovingBothFingersTogetherScrollsWithoutZoom() {
        var engine = PointerEngine()
        _ = engine.process(frame: frame(), bounds: bounds, configuration: configuration, timestamp: 1)
        let actions = engine.process(frame: frame(0.40, 0.70, y: 0.55), bounds: bounds, configuration: configuration, timestamp: 1.01)
        guard actions.count == 1, case let .scroll(dx, dy) = actions[0] else { return XCTFail("Expected scrolling: \(actions)") }
        XCTAssertEqual(dx, 50, accuracy: 0.001)
        XCTAssertEqual(dy, 50, accuracy: 0.001)
        XCTAssertEqual(engine.twoFingerIntent, .scrolling)
    }

    func testSerialUpdatesDoNotMistakeTheFirstMovingFingerForAPinch() {
        var engine = PointerEngine()
        _ = engine.process(frame: frame(0.30, 0.60), bounds: bounds, configuration: configuration, timestamp: 1)
        XCTAssertEqual(engine.process(frame: frame(0.40, 0.60), bounds: bounds, configuration: configuration, timestamp: 1.01), [])
        let actions = engine.process(frame: frame(0.40, 0.70), bounds: bounds, configuration: configuration, timestamp: 1.02)
        guard actions.count == 1, case let .scroll(dx, dy) = actions[0] else { return XCTFail("Expected scrolling: \(actions)") }
        XCTAssertEqual(dx, 100, accuracy: 0.001)
        XCTAssertEqual(dy, 0)
    }

    func testOneAnchoredFingerCanPinchAfterTheSerialGracePeriod() throws {
        var engine = PointerEngine()
        _ = engine.process(frame: frame(), bounds: bounds, configuration: configuration, timestamp: 1)
        XCTAssertEqual(engine.process(frame: frame(0.32, 0.65), bounds: bounds, configuration: configuration, timestamp: 1.02), [])
        let result = try XCTUnwrap(zoom(engine.process(frame: frame(0.32, 0.65), bounds: bounds, configuration: configuration, timestamp: 1.08)))
        XCTAssertGreaterThan(result.2, 0)
    }

    func testStationaryNoiseDoesNotZoomOrScroll() {
        var engine = PointerEngine()
        _ = engine.process(frame: frame(), bounds: bounds, configuration: configuration, timestamp: 1)
        XCTAssertEqual(engine.process(frame: frame(0.348, 0.652), bounds: bounds, configuration: configuration, timestamp: 1.1), [])
        XCTAssertEqual(engine.twoFingerIntent, .deciding)
    }

    func testPinchDoesNotTurnIntoScrollOrClickBeforeAllFingersLift() {
        var engine = PointerEngine()
        _ = engine.process(frame: frame(), bounds: bounds, configuration: configuration, timestamp: 1)
        _ = engine.process(frame: frame(0.30, 0.70), bounds: bounds, configuration: configuration, timestamp: 1.01)
        XCTAssertEqual(engine.process(frame: frame(0.35, 0.75), bounds: bounds, configuration: configuration, timestamp: 1.02), [])
        let one = TouchFrame(contacts: [TouchContact(id: 1, x: 0.35, y: 0.5)])
        XCTAssertEqual(engine.process(frame: one, bounds: bounds, configuration: configuration, timestamp: 1.03), [])
        XCTAssertEqual(engine.process(frame: frame(), bounds: bounds, configuration: configuration, timestamp: 1.04), [])
        _ = engine.process(frame: TouchFrame(contacts: []), bounds: bounds, configuration: configuration, timestamp: 1.05)
        XCTAssertEqual(engine.process(frame: one, bounds: bounds, configuration: configuration, timestamp: 1.06), [.move(x: 350, y: 500), .down(x: 350, y: 500)])
    }

    func testReplacingAContactOrAddingAThirdSuppressesZoomUntilLiftoff() {
        for changed in [frame(0.30, 0.70, secondID: 3), TouchFrame(contacts: frame().contacts + [TouchContact(id: 3, x: 0.8, y: 0.5)])] {
            var engine = PointerEngine()
            _ = engine.process(frame: frame(), bounds: bounds, configuration: configuration, timestamp: 1)
            XCTAssertEqual(engine.process(frame: changed, bounds: bounds, configuration: configuration, timestamp: 1.01), [])
            XCTAssertEqual(engine.process(frame: frame(0.30, 0.70), bounds: bounds, configuration: configuration, timestamp: 1.02), [])
        }
    }

    func testCancellationAndInvalidTimeDoNotCarryPinchState() {
        var engine = PointerEngine()
        _ = engine.process(frame: frame(), bounds: bounds, configuration: configuration, timestamp: 1)
        _ = engine.process(frame: frame(0.30, 0.70), bounds: bounds, configuration: configuration, timestamp: 1.01)
        XCTAssertEqual(engine.cancel(), [])
        XCTAssertNil(engine.twoFingerIntent)
        _ = engine.process(frame: frame(), bounds: bounds, configuration: configuration, timestamp: 2)
        XCTAssertEqual(engine.process(frame: frame(0.30, 0.70), bounds: bounds, configuration: configuration, timestamp: .nan), [])
        XCTAssertEqual(engine.process(frame: frame(0.30, 0.70), bounds: bounds, configuration: configuration, timestamp: 2.1), [])
    }

    func testModeChangeCancelsPinchAndRequiresLiftoff() {
        var engine = PointerEngine()
        _ = engine.process(frame: frame(), bounds: bounds, configuration: configuration, timestamp: 1)
        XCTAssertEqual(engine.process(frame: frame(0.30, 0.70), bounds: bounds, configuration: .init(), timestamp: 1.01), [])
        XCTAssertEqual(engine.process(frame: frame(), bounds: bounds, timestamp: 1.02), [])
    }

    func testLegacySavedProfileKeepsItsMappingAndScrollSettings() throws {
        let data = Data(#"{"rotation":90,"invertX":true,"invertY":false,"twoFingerScroll":false,"scrollSpeed":2.2}"#.utf8)
        let decoded = try JSONDecoder().decode(PointerConfiguration.self, from: data)
        XCTAssertEqual(decoded.rotation, 90)
        XCTAssertTrue(decoded.invertX)
        XCTAssertFalse(decoded.twoFingerScroll)
        XCTAssertEqual(decoded.scrollSpeed, 2.2)
        XCTAssertFalse(decoded.mapPinchZoom)
        let enabled = PointerConfiguration(rotation: 270, mapPinchZoom: true)
        XCTAssertEqual(try JSONDecoder().decode(PointerConfiguration.self, from: JSONEncoder().encode(enabled)), enabled)
    }

    func testPinchIsIndependentOfScrollSpeedAndCanWorkWithScrollDisabled() throws {
        var engine = PointerEngine()
        let config = PointerConfiguration(twoFingerScroll: false, scrollSpeed: 3, mapPinchZoom: true)
        _ = engine.process(frame: frame(), bounds: bounds, configuration: config, timestamp: 1)
        let result = try XCTUnwrap(zoom(engine.process(frame: frame(0.30, 0.70), bounds: bounds, configuration: config, timestamp: 1.01)))
        XCTAssertEqual(result.2, log(400.0 / 300) * 400, accuracy: 0.001)
    }

    func testLargeContactJumpIsSuppressedInsteadOfZooming() {
        var engine = PointerEngine()
        _ = engine.process(frame: frame(0.45, 0.55), bounds: bounds, configuration: configuration, timestamp: 1)
        XCTAssertEqual(engine.process(frame: frame(0.10, 0.90), bounds: bounds, configuration: configuration, timestamp: 1.1), [])
        XCTAssertEqual(engine.process(frame: frame(0.20, 0.80), bounds: bounds, configuration: configuration, timestamp: 1.2), [])
    }
}
