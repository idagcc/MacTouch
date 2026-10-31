import Foundation
import CoreGraphics
import XCTest
@testable import MacTouchCore

final class PointerEngineTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 101, height: 201)

    private func frame(_ values: (Int, Double, Double)...) -> TouchFrame {
        TouchFrame(contacts: values.map { TouchContact(id: $0.0, x: $0.1, y: $0.2) })
    }

    func testNegativeDisplayOriginAndEdges() {
        let bounds = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        XCTAssertEqual(CoordinateMapper.map(x: 0, y: 0, bounds: bounds), CGPoint(x: -1920, y: -200))
        XCTAssertEqual(CoordinateMapper.map(x: 1, y: 1, bounds: bounds), CGPoint(x: -1, y: 879))
        XCTAssertEqual(CoordinateMapper.map(x: -5, y: 3, bounds: bounds), CGPoint(x: -1920, y: 879))
    }

    func testAllRotationsAndInversions() {
        let expected: [(Int, CGPoint)] = [
            (0, CGPoint(x: 20, y: 60)), (90, CGPoint(x: 70, y: 40)),
            (180, CGPoint(x: 80, y: 140)), (270, CGPoint(x: 30, y: 160))
        ]
        for (rotation, point) in expected {
            let result = CoordinateMapper.map(x: 0.2, y: 0.3, bounds: bounds, configuration: .init(rotation: rotation))!
            XCTAssertEqual(result.x, point.x, accuracy: 0.0001)
            XCTAssertEqual(result.y, point.y, accuracy: 0.0001)
        }
        XCTAssertEqual(CoordinateMapper.map(x: 0, y: 0, bounds: bounds, configuration: .init(rotation: 90, invertX: true)), CGPoint(x: 100, y: 200))
        XCTAssertEqual(CoordinateMapper.map(x: 0, y: 0, bounds: bounds, configuration: .init(invertY: true)), CGPoint(x: 0, y: 200))
        XCTAssertEqual(CoordinateMapper.map(x: 0, y: 0, bounds: bounds, configuration: .init(rotation: -90)), CGPoint(x: 0, y: 200))
    }

    func testInvalidCoordinatesAndBoundsAreRejected() {
        XCTAssertNil(CoordinateMapper.map(x: .nan, y: 0, bounds: bounds))
        XCTAssertNil(CoordinateMapper.map(x: 0, y: .infinity, bounds: bounds))
        XCTAssertNil(CoordinateMapper.map(x: 0, y: 0, bounds: .zero))
        XCTAssertNil(CoordinateMapper.map(x: 0, y: 0, bounds: CGRect(x: 0, y: 0, width: -1, height: 100)))
        XCTAssertNil(CoordinateMapper.map(x: 0, y: 0, bounds: .infinite))
    }

    func testTapDragAndRelease() {
        var engine = PointerEngine()
        XCTAssertEqual(engine.process(frame: frame((8, 0.1, 0.2)), bounds: bounds), [.move(x: 10, y: 40), .down(x: 10, y: 40)])
        XCTAssertEqual(engine.process(frame: frame((8, 0.4, 0.5)), bounds: bounds), [.drag(x: 40, y: 100)])
        XCTAssertEqual(engine.process(frame: frame((8, 0.4, 0.5)), bounds: bounds), [])
        XCTAssertEqual(engine.process(frame: frame(), bounds: bounds), [.up(x: 40, y: 100)])
        XCTAssertEqual(engine.cancel(), [])
    }

    func testSecondFingerReleasesDragAndScrollDoesNotReclick() {
        var engine = PointerEngine()
        _ = engine.process(frame: frame((1, 0.2, 0.2)), bounds: bounds)
        XCTAssertEqual(engine.process(frame: frame((1, 0.2, 0.2), (2, 0.4, 0.4)), bounds: bounds), [.up(x: 20, y: 40), .move(x: 30, y: 60)])
        XCTAssertEqual(engine.process(frame: frame((2, 0.5, 0.5), (1, 0.3, 0.3)), bounds: bounds), [.scroll(dx: 10, dy: 20)])
        XCTAssertEqual(engine.process(frame: frame((1, 0.3, 0.3)), bounds: bounds), [])
        XCTAssertEqual(engine.process(frame: frame((1, 0.4, 0.4)), bounds: bounds), [])
        XCTAssertEqual(engine.process(frame: frame(), bounds: bounds), [])
        XCTAssertEqual(engine.process(frame: frame((1, 0.4, 0.4)), bounds: bounds), [.move(x: 40, y: 80), .down(x: 40, y: 80)])
    }

    func testContactReplacementCannotInheritHeldButton() {
        var engine = PointerEngine()
        _ = engine.process(frame: frame((1, 0.2, 0.2)), bounds: bounds)
        XCTAssertEqual(engine.process(frame: frame((2, 0.2, 0.2)), bounds: bounds), [.up(x: 20, y: 40)])
        XCTAssertEqual(engine.process(frame: frame((2, 0.3, 0.3)), bounds: bounds), [])
        XCTAssertEqual(engine.cancel(), [])
    }

    func testCancelAlwaysReleasesExactlyOnce() {
        var engine = PointerEngine()
        _ = engine.process(frame: frame((1, 1, 1)), bounds: bounds)
        XCTAssertEqual(engine.cancel(), [.up(x: 100, y: 200)])
        XCTAssertEqual(engine.cancel(), [])
        XCTAssertEqual(engine.process(frame: frame((2, 0, 0)), bounds: bounds), [.move(x: 0, y: 0), .down(x: 0, y: 0)])
    }

    func testMappingChangesReleaseAndWaitForLift() {
        var engine = PointerEngine()
        _ = engine.process(frame: frame((1, 0.2, 0.2)), bounds: bounds)
        XCTAssertEqual(engine.process(frame: frame((1, 0.2, 0.2)), bounds: bounds, configuration: .init(rotation: 90)), [.up(x: 20, y: 40)])
        XCTAssertEqual(engine.process(frame: frame((1, 0.2, 0.2)), bounds: bounds, configuration: .init(rotation: 90)), [])
        _ = engine.process(frame: frame(), bounds: bounds)
        _ = engine.process(frame: frame((1, 0.2, 0.2)), bounds: bounds)
        XCTAssertEqual(engine.process(frame: frame((1, 0.2, 0.2)), bounds: bounds.offsetBy(dx: -101, dy: 0)), [.up(x: 20, y: 40)])
    }

    func testInvalidAndDuplicateContactsReleaseAndSuppress() {
        for invalid in [frame((1, .nan, 0)), frame((1, 0, 0), (1, 0.2, 0.2)), frame((1, 0, 0), (2, 0, 0), (3, 0, 0))] {
            var engine = PointerEngine()
            _ = engine.process(frame: frame((1, 0.2, 0.2)), bounds: bounds)
            XCTAssertEqual(engine.process(frame: invalid, bounds: bounds), [.up(x: 20, y: 40)])
            XCTAssertEqual(engine.process(frame: frame((1, 0.2, 0.2)), bounds: bounds), [])
        }
    }

    func testDisabledTwoFingerScrollCannotLeaveButtonHeld() {
        var engine = PointerEngine()
        let config = PointerConfiguration(twoFingerScroll: false)
        _ = engine.process(frame: frame((1, 0.2, 0.2)), bounds: bounds, configuration: config)
        XCTAssertEqual(engine.process(frame: frame((1, 0.2, 0.2), (2, 0.4, 0.4)), bounds: bounds, configuration: config), [.up(x: 20, y: 40)])
        XCTAssertEqual(engine.process(frame: frame((1, 0.4, 0.4)), bounds: bounds, configuration: config), [])
    }

    func testScrollStartsWithoutClickAndUsesFiniteClampedSpeed() {
        for (speed, expected) in [(Double.nan, 10.0), (100.0, 40.0), (-5.0, 1.0)] {
            var engine = PointerEngine()
            let config = PointerConfiguration(scrollSpeed: speed)
            XCTAssertEqual(engine.process(frame: frame((1, 0.1, 0.2), (2, 0.3, 0.4)), bounds: bounds, configuration: config), [.move(x: 20, y: 60)])
            XCTAssertEqual(engine.process(frame: frame((1, 0.2, 0.3), (2, 0.4, 0.5)), bounds: bounds, configuration: config), [.scroll(dx: expected, dy: expected * 2)])
        }
    }

    func testScrollContactReplacementAndLargeJumpAreIgnored() {
        var engine = PointerEngine()
        _ = engine.process(frame: frame((1, 0, 0), (2, 0.1, 0.1)), bounds: bounds)
        XCTAssertEqual(engine.process(frame: frame((1, 0.8, 0.8), (2, 0.9, 0.9)), bounds: bounds), [])
        XCTAssertEqual(engine.process(frame: frame((1, 0.8, 0.8), (3, 0.9, 0.9)), bounds: bounds), [])
        XCTAssertEqual(engine.process(frame: frame((1, 0.7, 0.7), (3, 0.8, 0.8)), bounds: bounds), [])
    }
}
