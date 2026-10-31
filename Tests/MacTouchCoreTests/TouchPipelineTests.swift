import CoreGraphics
import Foundation
import XCTest
@testable import MacTouchCore

final class TouchPipelineTests: XCTestCase {
    // Standard serial touchscreen: a single Finger collection sends one
    // Contact Identifier per report, with no Contact Count field. A report
    // describes that contact's change, not the entire set of active fingers.
    private let serialDescriptor = Data([
        0x05, 0x0D, 0x09, 0x04, 0xA1, 0x01, // Digitizers / Touch Screen / Application
        0x09, 0x22, 0xA1, 0x02,             // Finger / Logical collection
        0x15, 0x00, 0x25, 0x01,
        0x75, 0x01, 0x95, 0x01,
        0x09, 0x42, 0x81, 0x02,             // 1-bit Tip Switch
        0x95, 0x07, 0x81, 0x03,             // 7 padding bits
        0x75, 0x08, 0x95, 0x01,
        0x26, 0xFF, 0x00, 0x09, 0x51,
        0x81, 0x02,                         // 8-bit Contact Identifier
        0x05, 0x01, 0x75, 0x10, 0x95, 0x02,
        0x15, 0x00, 0x26, 0xFF, 0x0F,
        0x09, 0x30, 0x09, 0x31, 0x81, 0x02, // Absolute X/Y, 0...4095
        0xC0, 0xC0
    ] as [UInt8])
    // This size makes each raw coordinate one global display coordinate.
    private let bounds = CGRect(x: 0, y: 0, width: 4096, height: 4096)

    private func report(id: UInt8, x: UInt16, y: UInt16, down: Bool = true) -> Data {
        Data([down ? 1 : 0, id, UInt8(x & 0xFF), UInt8(x >> 8),
              UInt8(y & 0xFF), UInt8(y >> 8)])
    }

    func testSerialTwoFingerInputReachesPreviewAndScrollWithoutReclicking() throws {
        var decoder = HIDReportDecoder(descriptor: try HIDDescriptor(data: serialDescriptor))
        var engine = PointerEngine()

        let first = try XCTUnwrap(decoder.decode(report: report(id: 4, x: 400, y: 800), timestamp: 1))
        XCTAssertEqual(first.contacts.map(\.id), [4])
        assertActions(engine.process(frame: first, bounds: bounds), [.move(x: 400, y: 800), .down(x: 400, y: 800)])

        // This is the reported hardware symptom: two down packets must expose
        // TWO contacts to Live Touch and the pointer engine, even when only
        // the second contact is present in the latest wire report.
        let second = try XCTUnwrap(decoder.decode(report: report(id: 9, x: 800, y: 1000), timestamp: 1.001))
        XCTAssertEqual(Set(second.contacts.map(\.id)), [4, 9])
        XCTAssertEqual(second.contacts.count, 2)
        assertActions(engine.process(frame: second, bounds: bounds), [.up(x: 400, y: 800), .move(x: 600, y: 900)])

        let moveFirst = try XCTUnwrap(decoder.decode(report: report(id: 4, x: 400, y: 900), timestamp: 1.002))
        XCTAssertEqual(moveFirst.contacts.count, 2)
        assertActions(engine.process(frame: moveFirst, bounds: bounds), [.scroll(dx: 0, dy: 50)])
        let moveSecond = try XCTUnwrap(decoder.decode(report: report(id: 9, x: 800, y: 1100), timestamp: 1.003))
        assertActions(engine.process(frame: moveSecond, bounds: bounds), [.scroll(dx: 0, dy: 50)])

        let partialLift = try XCTUnwrap(decoder.decode(report: report(id: 4, x: 400, y: 900, down: false), timestamp: 1.004))
        XCTAssertEqual(partialLift.contacts.map(\.id), [9])
        XCTAssertEqual(engine.process(frame: partialLift, bounds: bounds), [])
        let remainingMoves = try XCTUnwrap(decoder.decode(report: report(id: 9, x: 800, y: 1200), timestamp: 1.005))
        XCTAssertEqual(engine.process(frame: remainingMoves, bounds: bounds), [], "The remaining finger must not turn back into a click or drag.")

        let allLifted = try XCTUnwrap(decoder.decode(report: report(id: 9, x: 800, y: 1200, down: false), timestamp: 1.006))
        XCTAssertTrue(allLifted.contacts.isEmpty)
        XCTAssertEqual(engine.process(frame: allLifted, bounds: bounds), [])

        let newTap = try XCTUnwrap(decoder.decode(report: report(id: 4, x: 1000, y: 500), timestamp: 1.007))
        assertActions(engine.process(frame: newTap, bounds: bounds), [.move(x: 1000, y: 500), .down(x: 1000, y: 500)])
        let tapRelease = try XCTUnwrap(decoder.decode(report: report(id: 4, x: 1000, y: 500, down: false), timestamp: 1.008))
        assertActions(engine.process(frame: tapRelease, bounds: bounds), [.up(x: 1000, y: 500)])
    }

    func testResetCannotCarryOldSerialContactsIntoReconnectedGesture() throws {
        var decoder = HIDReportDecoder(descriptor: try HIDDescriptor(data: serialDescriptor))
        var engine = PointerEngine()
        for (index, id) in [UInt8(4), UInt8(9)].enumerated() {
            let frame = try XCTUnwrap(decoder.decode(report: report(id: id, x: UInt16(id) * 100, y: 800), timestamp: 1 + Double(index) / 1000))
            _ = engine.process(frame: frame, bounds: bounds)
        }

        // Mirrors resetting a device decoder and cancelling pointer ownership
        // on disconnect/rescan. Its next report must start from an empty cache.
        decoder.reset()
        XCTAssertEqual(engine.cancel(), [])
        let reconnected = try XCTUnwrap(decoder.decode(report: report(id: 12, x: 1200, y: 600), timestamp: 2))
        XCTAssertEqual(reconnected.contacts.map(\.id), [12])
        assertActions(engine.process(frame: reconnected, bounds: bounds), [.move(x: 1200, y: 600), .down(x: 1200, y: 600)])

        decoder.reset()
        assertActions(engine.cancel(), [.up(x: 1200, y: 600)])
        let oldLift = try XCTUnwrap(decoder.decode(report: report(id: 9, x: 900, y: 800, down: false), timestamp: 3))
        XCTAssertTrue(oldLift.contacts.isEmpty)
        XCTAssertEqual(engine.process(frame: oldLift, bounds: bounds), [])
    }

    func testSerialContactSeparationReachesMapZoomWithoutScrolling() throws {
        var decoder = HIDReportDecoder(descriptor: try HIDDescriptor(data: serialDescriptor))
        var engine = PointerEngine()
        let config = PointerConfiguration(mapPinchZoom: true)
        let packets: [(Data, TimeInterval)] = [
            (report(id: 4, x: 400, y: 800), 1),
            (report(id: 9, x: 800, y: 800), 1.001),
            (report(id: 4, x: 350, y: 800), 1.01),
            (report(id: 9, x: 850, y: 800), 1.02)
        ]
        var outputs: [[PointerAction]] = []
        for (packet, timestamp) in packets {
            let decoded = try XCTUnwrap(decoder.decode(report: packet, timestamp: timestamp))
            outputs.append(engine.process(frame: decoded, bounds: bounds, configuration: config, timestamp: timestamp))
        }
        assertActions(outputs[1], [.up(x: 400, y: 800), .move(x: 600, y: 800)])
        XCTAssertEqual(outputs[2], [], "Wait for the other serial contact before deciding between pinch and scroll.")
        guard outputs[3].count == 1, case let .mapZoom(x, y, delta) = outputs[3][0] else {
            return XCTFail("Expected embedded-map zoom, received \(outputs[3])")
        }
        XCTAssertEqual(x, 600, accuracy: 0.001)
        XCTAssertEqual(y, 800, accuracy: 0.001)
        XCTAssertGreaterThan(delta, 0)
    }

    private func assertActions(_ actual: [PointerAction], _ expected: [PointerAction],
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actual, expected) in zip(actual, expected) {
            switch (actual, expected) {
            case let (.move(ax, ay), .move(ex, ey)),
                 let (.down(ax, ay), .down(ex, ey)),
                 let (.drag(ax, ay), .drag(ex, ey)),
                 let (.up(ax, ay), .up(ex, ey)),
                 let (.scroll(ax, ay), .scroll(ex, ey)):
                XCTAssertEqual(ax, ex, accuracy: 0.000001, file: file, line: line)
                XCTAssertEqual(ay, ey, accuracy: 0.000001, file: file, line: line)
            default:
                XCTFail("Expected \(expected), received \(actual)", file: file, line: line)
            }
        }
    }
}
