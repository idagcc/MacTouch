import XCTest
@testable import MacTouchCore

final class TouchTestSessionTests: XCTestCase {
    private func frame(_ count: Int) -> TouchFrame {
        TouchFrame(contacts: (0..<count).map { TouchContact(id: $0, x: 0.5, y: 0.5) })
    }

    func testBriefThreeFingerFrameRemainsMeasuredAfterLiftoff() {
        var session = TouchTestSession()
        for count in [1, 2, 3, 2, 1, 0] { session.record(frame(count)) }
        XCTAssertEqual(session.currentContacts, 0)
        XCTAssertEqual(session.peakContacts, 3)
        XCTAssertEqual(session.frames, 6)
    }

    func testDisconnectClearsContactsWithoutClaimingAnotherSensorFrame() {
        var session = TouchTestSession()
        session.record(frame(10))
        session.clearContacts()
        XCTAssertEqual(session.currentContacts, 0)
        XCTAssertEqual(session.peakContacts, 10)
        XCTAssertEqual(session.frames, 1)
    }

    func testResetStartsFreshMeasurements() {
        var session = TouchTestSession()
        session.record(frame(3))
        session.reset()
        session.record(frame(1))
        XCTAssertEqual(session.currentContacts, 1)
        XCTAssertEqual(session.peakContacts, 1)
        XCTAssertEqual(session.frames, 1)
    }
}
