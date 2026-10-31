import Foundation
import XCTest
@testable import MacTouchCore

final class HIDTests: XCTestCase {
    // Synthetic HID descriptors follow USB HID 1.11 and the standard digitizer
    // usages documented by USB-IF and Microsoft's touchscreen guidelines.
    private func descriptor(slots: Int = 1, numbered: Bool = false, count: Bool = false,
                            confidence: Bool = false, signedAxes: Bool = false,
                            identifiers: Bool = true, axisRange: Bool = false,
                            scanTime: Bool = false) -> [UInt8] {
        var bytes: [UInt8] = [0x05, 0x0D, 0x09, 0x04, 0xA1, 0x01]
        if numbered { bytes += [0x85, 0x07] }
        for _ in 0..<slots {
            bytes += [0x05, 0x0D, 0x09, 0x22, 0xA1, 0x02,
                      0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x01,
                      0x09, 0x42, 0x81, 0x02]
            if confidence { bytes += [0x09, 0x47, 0x81, 0x02] }
            bytes += [0x95, confidence ? 0x06 : 0x07, 0x81, 0x03]
            if identifiers {
                bytes += [0x75, 0x08, 0x95, 0x01, 0x26, 0xFF, 0x00,
                          0x09, 0x51, 0x81, 0x02]
            }
            bytes += [0x05, 0x01, 0x75, 0x10, 0x95, 0x02]
            if signedAxes { bytes += [0x16, 0x00, 0x80, 0x26, 0xFF, 0x7F] }
            else { bytes += [0x15, 0x00, 0x26, 0xFF, 0x0F] }
            if axisRange { bytes += [0x19, 0x30, 0x29, 0x31] }
            else { bytes += [0x09, 0x30, 0x09, 0x31] }
            bytes += [0x81, 0x02, 0xC0]
        }
        if count {
            bytes += [0x05, 0x0D, 0x09, 0x54, 0x15, 0x00, 0x25, 0x20,
                      0x75, 0x08, 0x95, 0x01, 0x81, 0x02]
        }
        if scanTime {
            bytes += [0x05, 0x0D, 0x09, 0x56, 0x15, 0x00, 0x26, 0xFF, 0xFF,
                      0x75, 0x10, 0x95, 0x01, 0x81, 0x02]
        }
        bytes += [0xC0]
        return bytes
    }

    private func slot(tip: UInt8 = 1, id: UInt8 = 0, x: UInt16, y: UInt16) -> [UInt8] {
        [tip, id, UInt8(x & 0xFF), UInt8(x >> 8), UInt8(y & 0xFF), UInt8(y >> 8)]
    }

    func testSingleTouchNormalizesLogicalCoordinatesAndReleases() throws {
        let hid = try HIDDescriptor(data: Data(descriptor()))
        XCTAssertEqual(hid.reportIDs, [0])
        XCTAssertFalse(hid.usesReportIDs)
        let frame = try XCTUnwrap(hid.decode(report: Data(slot(id: 9, x: 4095, y: 2048))))
        XCTAssertEqual(frame.contacts.count, 1)
        XCTAssertEqual(frame.contacts[0].id, 9)
        XCTAssertEqual(frame.contacts[0].x, 1)
        XCTAssertEqual(frame.contacts[0].y, 2048.0 / 4095, accuracy: 0.000001)
        XCTAssertEqual(try hid.decode(report: Data(slot(tip: 0, x: 0, y: 0)))?.contacts, [])
    }

    func testReportIDPrefixAndUnrelatedReports() throws {
        let hid = try HIDDescriptor(data: Data(descriptor(numbered: true)))
        XCTAssertEqual(hid.reportIDs, [7])
        XCTAssertTrue(hid.usesReportIDs)
        XCTAssertEqual(try hid.decode(report: Data([7] + slot(x: 100, y: 200)))?.contacts.count, 1)
        XCTAssertNil(try hid.decode(report: Data([8, 0, 0])))
        XCTAssertThrowsError(try hid.decode(report: Data([7, 0, 0])))
    }

    func testParallelContactsHaveStableIdentifiers() throws {
        let hid = try HIDDescriptor(data: Data(descriptor(slots: 2, count: true)))
        let frame = try XCTUnwrap(hid.decode(report: Data(slot(id: 4, x: 0, y: 0) + slot(id: 8, x: 4095, y: 4095) + [2])))
        XCTAssertEqual(frame.contacts, [TouchContact(id: 4, x: 0, y: 0), TouchContact(id: 8, x: 1, y: 1)])
    }

    func testContactCountIncludesLiftOffSlots() throws {
        let hid = try HIDDescriptor(data: Data(descriptor(slots: 2, count: true)))
        let bytes = slot(tip: 0, id: 4, x: 0, y: 0) + slot(id: 8, x: 4095, y: 4095) + [2]
        XCTAssertEqual(try hid.decode(report: Data(bytes))?.contacts.map(\.id), [8])
    }

    func testUnreportedSlotsAreIgnored() throws {
        let hid = try HIDDescriptor(data: Data(descriptor(slots: 2, count: true)))
        let bytes = slot(id: 4, x: 0, y: 0) + slot(id: 4, x: 65535, y: 65535) + [1]
        XCTAssertEqual(try hid.decode(report: Data(bytes))?.contacts.map(\.id), [4])
    }

    func testHybridAndContinuationReportsAreRejected() throws {
        let hid = try HIDDescriptor(data: Data(descriptor(slots: 2, count: true)))
        let active = slot(id: 1, x: 0, y: 0) + slot(id: 2, x: 4095, y: 4095)
        XCTAssertThrowsError(try hid.decode(report: Data(active + [3])))
        XCTAssertThrowsError(try hid.decode(report: Data(active + [0])))
        let released = slot(tip: 0, x: 0, y: 0) + slot(tip: 0, x: 0, y: 0)
        XCTAssertEqual(try hid.decode(report: Data(released + [0]))?.contacts, [])
    }

    func testConfidenceSuppressesUnintentionalTouch() throws {
        let hid = try HIDDescriptor(data: Data(descriptor(confidence: true)))
        XCTAssertEqual(try hid.decode(report: Data(slot(tip: 1, x: 200, y: 200)))?.contacts, [])
        XCTAssertEqual(try hid.decode(report: Data(slot(tip: 3, x: 200, y: 200)))?.contacts.count, 1)
    }

    func testSignedCoordinateBounds() throws {
        let hid = try HIDDescriptor(data: Data(descriptor(signedAxes: true)))
        let frame = try XCTUnwrap(hid.decode(report: Data(slot(x: 0x8000, y: 0x7FFF))))
        XCTAssertEqual(frame.contacts[0].x, 0)
        XCTAssertEqual(frame.contacts[0].y, 1)
    }

    func testUsageRanges() throws {
        let hid = try HIDDescriptor(data: Data(descriptor(axisRange: true)))
        XCTAssertEqual(try hid.decode(report: Data(slot(x: 4095, y: 0)))?.contacts, [TouchContact(id: 0, x: 1, y: 0)])
    }

    func testPushPopRestoresGlobalFieldLayout() throws {
        var bytes = descriptor()
        // Insert a saved global-state mutation before the X/Y item.
        let position = try XCTUnwrap(bytes.firstIndex(of: 0x09, startingAt: 40))
        bytes.insert(contentsOf: [0xA4, 0x75, 0x01, 0x95, 0x01, 0x05, 0xFF, 0xB4], at: position)
        let hid = try HIDDescriptor(data: Data(bytes))
        XCTAssertEqual(try hid.decode(report: Data(slot(x: 4095, y: 0)))?.contacts[0].x, 1)
    }

    func testDuplicateIdentifiersRejected() throws {
        let hid = try HIDDescriptor(data: Data(descriptor(slots: 2, count: true)))
        XCTAssertThrowsError(try hid.decode(report: Data(slot(id: 3, x: 0, y: 0) + slot(id: 3, x: 200, y: 200) + [2])))
    }

    func testOutOfRangeAndTruncatedReportsRejected() throws {
        let hid = try HIDDescriptor(data: Data(descriptor()))
        XCTAssertThrowsError(try hid.decode(report: Data(slot(x: 4096, y: 0))))
        XCTAssertThrowsError(try hid.decode(report: Data([1, 0, 0])))
        XCTAssertThrowsError(try hid.decode(report: Data()))
    }

    func testOnlyZeroEndpointPaddingIsAccepted() throws {
        let hid = try HIDDescriptor(data: Data(descriptor()))
        XCTAssertEqual(try hid.decode(report: Data(slot(x: 0, y: 0) + [0, 0]))?.contacts.count, 1)
        XCTAssertThrowsError(try hid.decode(report: Data(slot(x: 0, y: 0) + [0, 1])))
    }

    func testSingleTouchWithoutIdentifier() throws {
        let hid = try HIDDescriptor(data: Data(descriptor(identifiers: false)))
        XCTAssertEqual(try hid.decode(report: Data([1, 0xFF, 0x0F, 0, 0]))?.contacts, [TouchContact(id: 0, x: 1, y: 0)])
    }

    func testMultiContactNeedsCountAndIdentifiers() {
        XCTAssertThrowsError(try HIDDescriptor(data: Data(descriptor(slots: 2))))
        XCTAssertThrowsError(try HIDDescriptor(data: Data(descriptor(slots: 2, count: true, identifiers: false))))
    }

    func testMouseAndTouchpadCollectionsCannotBecomeTouchscreens() {
        var mouse = descriptor()
        mouse[1] = 1
        mouse[3] = 2
        XCTAssertThrowsError(try HIDDescriptor(data: Data(mouse)))
        var touchpad = descriptor()
        touchpad[3] = 5
        XCTAssertThrowsError(try HIDDescriptor(data: Data(touchpad)))
    }

    func testRelativeAndArrayAxesAreRejected() {
        var relative = descriptor()
        relative[relative.count - 3] = 0x06
        XCTAssertThrowsError(try HIDDescriptor(data: Data(relative)))
        var array = descriptor()
        array[array.count - 3] = 0
        XCTAssertThrowsError(try HIDDescriptor(data: Data(array)))
    }

    func testConstantsAndOtherReportTypesDoNotShiftInput() throws {
        var bytes = descriptor()
        bytes.insert(contentsOf: [0x09, 0x55, 0xB1, 0x02, 0x09, 0x55, 0x91, 0x02], at: 6)
        let hid = try HIDDescriptor(data: Data(bytes))
        XCTAssertEqual(try hid.decode(report: Data(slot(x: 4095, y: 0)))?.contacts[0].x, 1)
    }

    func testMalformedDescriptorsFailClosed() {
        for bytes: [UInt8] in [[], [0x05], [0xC0], [0xB4], [0xFE, 0, 0], [0x05, 0x0D, 0x09, 0x04, 0xA1, 0x01]] {
            XCTAssertThrowsError(try HIDDescriptor(data: Data(bytes)))
        }
        var zeroID = descriptor(numbered: true)
        zeroID[7] = 0
        XCTAssertThrowsError(try HIDDescriptor(data: Data(zeroID)))
        var oversized = descriptor()
        oversized.insert(contentsOf: [0x97, 0xFF, 0xFF, 0xFF, 0x7F], at: 6)
        XCTAssertThrowsError(try HIDDescriptor(data: Data(oversized)))
    }

    func testEveryTruncatedDescriptorPrefixIsRejected() {
        let bytes = descriptor(slots: 2, numbered: true, count: true)
        for length in 0..<bytes.count {
            XCTAssertThrowsError(try HIDDescriptor(data: Data(bytes.prefix(length))), "prefix length \(length)")
        }
    }

    func testDeterministicMalformedDataNeverCrashesParser() {
        var random: UInt64 = 0xDECAFBAD
        for length in 0..<256 {
            let bytes: [UInt8] = (0..<length).map { _ in
                random = random &* 6364136223846793005 &+ 1
                return UInt8(truncatingIfNeeded: random >> 32)
            }
            _ = try? HIDDescriptor(data: Data(bytes))
        }
    }

    private func hybridPacket(_ ids: [UInt8], count: UInt8, scan: UInt16 = 100,
                              released: Set<UInt8> = []) -> Data {
        var bytes: [UInt8] = []
        for id in ids { bytes += slot(tip: released.contains(id) ? 0 : 1, id: id, x: UInt16(id) * 100, y: 100) }
        bytes += [count, UInt8(scan & 0xFF), UInt8(scan >> 8)]
        return Data(bytes)
    }

    func testStatefulHybridEmitsOnlyCompleteFrame() throws {
        var decoder = HIDReportDecoder(descriptor: try HIDDescriptor(data: Data(descriptor(slots: 2, count: true, scanTime: true))))
        XCTAssertNil(try decoder.decode(report: hybridPacket([1, 2], count: 3), timestamp: 1))
        XCTAssertTrue(decoder.isAssemblingFrame)
        XCTAssertTrue(decoder.usesHybridFrames)
        // The unused second slot of the final packet is deliberately duplicate.
        let completed = try decoder.decode(report: hybridPacket([3, 3], count: 0), timestamp: 1.005)
        XCTAssertEqual(completed?.contacts.map(\.id), [1, 2, 3])
        XCTAssertFalse(decoder.isAssemblingFrame)
    }

    func testHybridCountsLiftoffEntriesAndFiltersConfidence() throws {
        var decoder = HIDReportDecoder(descriptor: try HIDDescriptor(data: Data(descriptor(slots: 2, count: true, scanTime: true))))
        XCTAssertNil(try decoder.decode(report: hybridPacket([1, 2], count: 4, released: [1]), timestamp: 1))
        let frame = try decoder.decode(report: hybridPacket([3, 4], count: 0, released: [4]), timestamp: 1.01)
        XCTAssertEqual(frame?.contacts.map(\.id), [2, 3])
    }

    func testHybridDeadlineResetsAndNextFrameCanRecover() throws {
        var decoder = HIDReportDecoder(descriptor: try HIDDescriptor(data: Data(descriptor(slots: 2, count: true, scanTime: true))))
        XCTAssertNil(try decoder.decode(report: hybridPacket([1, 2], count: 3), timestamp: 1))
        XCTAssertThrowsError(try decoder.decode(report: hybridPacket([3, 3], count: 0), timestamp: 1.051))
        XCTAssertFalse(decoder.isAssemblingFrame)
        XCTAssertEqual(try decoder.decode(report: hybridPacket([5, 6], count: 2, scan: 101), timestamp: 1.06)?.contacts.map(\.id), [5, 6])
    }

    func testHybridScanMismatchAndNewFrameInterruptReset() throws {
        let descriptor = try HIDDescriptor(data: Data(descriptor(slots: 2, count: true, scanTime: true)))
        var decoder = HIDReportDecoder(descriptor: descriptor)
        XCTAssertNil(try decoder.decode(report: hybridPacket([1, 2], count: 3), timestamp: 1))
        XCTAssertThrowsError(try decoder.decode(report: hybridPacket([3, 3], count: 0, scan: 101), timestamp: 1.01))
        XCTAssertFalse(decoder.isAssemblingFrame)
        XCTAssertNil(try decoder.decode(report: hybridPacket([1, 2], count: 3), timestamp: 2))
        XCTAssertThrowsError(try decoder.decode(report: hybridPacket([3, 4], count: 2), timestamp: 2.01))
        XCTAssertFalse(decoder.isAssemblingFrame)
    }

    func testHybridRejectsDuplicateIdentifiersAcrossPackets() throws {
        var decoder = HIDReportDecoder(descriptor: try HIDDescriptor(data: Data(descriptor(slots: 2, count: true, scanTime: true))))
        XCTAssertNil(try decoder.decode(report: hybridPacket([1, 2], count: 3), timestamp: 1))
        XCTAssertThrowsError(try decoder.decode(report: hybridPacket([1, 3], count: 0), timestamp: 1.005))
        XCTAssertFalse(decoder.isAssemblingFrame)
    }

    func testHybridRequiresScanTimeAndKeepsStrictDecoderStrict() throws {
        let hid = try HIDDescriptor(data: Data(descriptor(slots: 2, count: true)))
        var decoder = HIDReportDecoder(descriptor: hid)
        let packet = Data(slot(id: 1, x: 0, y: 0) + slot(id: 2, x: 0, y: 0) + [3])
        XCTAssertThrowsError(try decoder.decode(report: packet, timestamp: 1))
        XCTAssertThrowsError(try hid.decode(report: packet))
    }

    func testHybridResetAndDeviceIsolation() throws {
        let hid = try HIDDescriptor(data: Data(descriptor(slots: 2, count: true, scanTime: true)))
        var first = HIDReportDecoder(descriptor: hid)
        var second = HIDReportDecoder(descriptor: hid)
        XCTAssertNil(try first.decode(report: hybridPacket([1, 2], count: 3, scan: 100), timestamp: 1))
        XCTAssertNil(try second.decode(report: hybridPacket([5, 6], count: 3, scan: 200), timestamp: 1))
        XCTAssertEqual(try second.decode(report: hybridPacket([7, 7], count: 0, scan: 200), timestamp: 1.005)?.contacts.map(\.id), [5, 6, 7])
        first.reset()
        XCTAssertThrowsError(try first.decode(report: hybridPacket([3, 3], count: 0), timestamp: 1.01))
    }

    func testHybridScanTimeCanWrapBetweenCompletedFrames() throws {
        var decoder = HIDReportDecoder(descriptor: try HIDDescriptor(data: Data(descriptor(slots: 2, count: true, scanTime: true))))
        XCTAssertNil(try decoder.decode(report: hybridPacket([1, 2], count: 3, scan: 65535), timestamp: 1))
        XCTAssertEqual(try decoder.decode(report: hybridPacket([3, 3], count: 0, scan: 65535), timestamp: 1.001)?.contacts.count, 3)
        XCTAssertNil(try decoder.decode(report: hybridPacket([1, 2], count: 3, scan: 0), timestamp: 1.002))
        XCTAssertEqual(try decoder.decode(report: hybridPacket([3, 3], count: 0, scan: 0), timestamp: 1.003)?.contacts.count, 3)
    }

    func testHybridContactCapAndInvalidTime() throws {
        var bytes = descriptor(slots: 2, count: true, scanTime: true)
        // Expand Contact Count's logical range to exercise the independent cap.
        let countUsage = try XCTUnwrap(bytes.indices.dropLast().first { bytes[$0] == 0x09 && bytes[$0 + 1] == 0x54 })
        bytes[countUsage + 5] = 0x7F
        let hid = try HIDDescriptor(data: Data(bytes))
        var decoder = HIDReportDecoder(descriptor: hid)
        XCTAssertThrowsError(try decoder.decode(report: hybridPacket([1, 2], count: 33), timestamp: 1))
        XCTAssertThrowsError(try decoder.decode(report: hybridPacket([1, 2], count: 2), timestamp: .nan))
        XCTAssertNil(try decoder.decode(report: hybridPacket([1, 2], count: 3), timestamp: 2))
        XCTAssertThrowsError(try decoder.decode(report: hybridPacket([3, 3], count: 0), timestamp: 1.99))
    }

    func testSingleSlotHybridAndZeroContactRelease() throws {
        var decoder = HIDReportDecoder(descriptor: try HIDDescriptor(data: Data(descriptor(slots: 1, count: true, scanTime: true))))
        XCTAssertNil(try decoder.decode(report: hybridPacket([1], count: 2), timestamp: 1))
        XCTAssertEqual(try decoder.decode(report: hybridPacket([2], count: 0), timestamp: 1.001)?.contacts.map(\.id), [1, 2])
        XCTAssertEqual(try decoder.decode(report: hybridPacket([1], count: 0, released: [1]), timestamp: 1.002)?.contacts, [])
    }

    func testSerialPacketsAccumulateMultipleHeldContacts() throws {
        let hid = try HIDDescriptor(data: Data(descriptor()))
        XCTAssertEqual(hid.framing, .serialContacts)
        XCTAssertTrue(hid.summary.contains("serial"))
        var decoder = HIDReportDecoder(descriptor: hid)
        XCTAssertTrue(decoder.usesSerialContacts)
        XCTAssertEqual(try decoder.decode(report: Data(slot(id: 1, x: 100, y: 200)), timestamp: 1)?.contacts.map(\.id), [1])
        XCTAssertEqual(try decoder.decode(report: Data(slot(id: 2, x: 300, y: 400)), timestamp: 1.001)?.contacts.map(\.id), [1, 2])
        XCTAssertEqual(try decoder.decode(report: Data(slot(id: 3, x: 500, y: 600)), timestamp: 1.002)?.contacts.map(\.id), [1, 2, 3])
    }

    func testSerialRepeatedContactUpdatesPreserveOtherFingers() throws {
        var decoder = HIDReportDecoder(descriptor: try HIDDescriptor(data: Data(descriptor())))
        _ = try decoder.decode(report: Data(slot(id: 1, x: 100, y: 200)), timestamp: 1)
        _ = try decoder.decode(report: Data(slot(id: 2, x: 300, y: 400)), timestamp: 1.001)
        let update = try XCTUnwrap(decoder.decode(report: Data(slot(id: 1, x: 4095, y: 0)), timestamp: 1.002))
        XCTAssertEqual(update.contacts.count, 2)
        XCTAssertEqual(update.contacts[0], TouchContact(id: 1, x: 1, y: 0))
        XCTAssertEqual(update.contacts[1].x, 300.0 / 4095, accuracy: 0.000001)
    }

    func testSerialLiftRemovesOnlyNamedContactAndAllowsReuse() throws {
        var decoder = HIDReportDecoder(descriptor: try HIDDescriptor(data: Data(descriptor())))
        _ = try decoder.decode(report: Data(slot(id: 1, x: 100, y: 200)), timestamp: 1)
        _ = try decoder.decode(report: Data(slot(id: 2, x: 300, y: 400)), timestamp: 1.001)
        XCTAssertEqual(try decoder.decode(report: Data(slot(tip: 0, id: 1, x: 100, y: 200)), timestamp: 1.002)?.contacts.map(\.id), [2])
        XCTAssertEqual(try decoder.decode(report: Data(slot(tip: 0, id: 2, x: 300, y: 400)), timestamp: 1.003)?.contacts, [])
        XCTAssertEqual(try decoder.decode(report: Data(slot(id: 1, x: 4095, y: 0)), timestamp: 1.004)?.contacts, [TouchContact(id: 1, x: 1, y: 0)])
    }

    func testSerialConfidenceReleaseDoesNotEraseOtherContact() throws {
        var decoder = HIDReportDecoder(descriptor: try HIDDescriptor(data: Data(descriptor(confidence: true))))
        _ = try decoder.decode(report: Data(slot(tip: 3, id: 1, x: 100, y: 200)), timestamp: 1)
        _ = try decoder.decode(report: Data(slot(tip: 3, id: 2, x: 300, y: 400)), timestamp: 1.001)
        XCTAssertEqual(try decoder.decode(report: Data(slot(tip: 1, id: 1, x: 100, y: 200)), timestamp: 1.002)?.contacts.map(\.id), [2])
        // A release for an unseen ID cannot delete a different held finger.
        XCTAssertEqual(try decoder.decode(report: Data(slot(tip: 0, id: 9, x: 0, y: 0)), timestamp: 1.003)?.contacts.map(\.id), [2])
    }

    func testSerialResetAndDecodeFailureClearAllHeldContacts() throws {
        var decoder = HIDReportDecoder(descriptor: try HIDDescriptor(data: Data(descriptor())))
        _ = try decoder.decode(report: Data(slot(id: 1, x: 100, y: 200)), timestamp: 1)
        decoder.reset()
        XCTAssertEqual(try decoder.decode(report: Data(slot(id: 2, x: 300, y: 400)), timestamp: 2)?.contacts.map(\.id), [2])
        XCTAssertThrowsError(try decoder.decode(report: Data([1, 3]), timestamp: 2.001))
        XCTAssertEqual(try decoder.decode(report: Data(slot(id: 4, x: 300, y: 400)), timestamp: 2.002)?.contacts.map(\.id), [4])
    }

    func testSerialContactCapAndInvalidTimestampClearState() throws {
        var decoder = HIDReportDecoder(descriptor: try HIDDescriptor(data: Data(descriptor())))
        for id: UInt8 in 0..<32 {
            let frame = try decoder.decode(report: Data(slot(id: id, x: 100, y: 200)), timestamp: Double(id))
            XCTAssertEqual(frame?.contacts.count, Int(id) + 1)
        }
        XCTAssertThrowsError(try decoder.decode(report: Data(slot(id: 32, x: 100, y: 200)), timestamp: 32))
        XCTAssertEqual(try decoder.decode(report: Data(slot(id: 33, x: 100, y: 200)), timestamp: 33)?.contacts.map(\.id), [33])
        XCTAssertThrowsError(try decoder.decode(report: Data(slot(id: 34, x: 100, y: 200)), timestamp: 32.999))
        XCTAssertEqual(try decoder.decode(report: Data(slot(id: 35, x: 100, y: 200)), timestamp: 34)?.contacts.map(\.id), [35])
    }

    func testNoIdentifierSingleTouchAndCountedFramesRemainStateless() throws {
        let single = try HIDDescriptor(data: Data(descriptor(identifiers: false)))
        XCTAssertEqual(single.framing, .completeFrames)
        var decoder = HIDReportDecoder(descriptor: single)
        XCTAssertFalse(decoder.usesSerialContacts)
        _ = try decoder.decode(report: Data([1, 0, 0, 0, 0]), timestamp: 1)
        XCTAssertEqual(try decoder.decode(report: Data([1, 0xFF, 0x0F, 0, 0]), timestamp: 1.001)?.contacts, [TouchContact(id: 0, x: 1, y: 0)])
        let counted = try HIDDescriptor(data: Data(descriptor(count: true)))
        XCTAssertEqual(counted.framing, .completeFrames)
        decoder = HIDReportDecoder(descriptor: counted)
        _ = try decoder.decode(report: Data(slot(id: 1, x: 0, y: 0) + [1]), timestamp: 2)
        XCTAssertEqual(try decoder.decode(report: Data(slot(id: 2, x: 0, y: 0) + [1]), timestamp: 2.001)?.contacts.map(\.id), [2])
    }

    func testTipAndCentreArraysUseTheIntendedTouchPoint() throws {
        var bytes = descriptor()
        let axisStart = try XCTUnwrap(bytes.indices.dropLast().first { bytes[$0] == 0x09 && bytes[$0 + 1] == 0x30 })
        // Two X values (tip, centre), followed by two Y values (tip, centre).
        bytes.replaceSubrange(axisStart..<(bytes.count - 2), with: [0x09, 0x30, 0x81, 0x02, 0x09, 0x31, 0x81, 0x02])
        let hid = try HIDDescriptor(data: Data(bytes))
        let frame = try XCTUnwrap(hid.decode(report: Data([1, 1, 100, 0, 200, 0, 44, 1, 144, 1])))
        XCTAssertEqual(frame.contacts[0].x, 100.0 / 4095, accuracy: 0.000001)
        XCTAssertEqual(frame.contacts[0].y, 300.0 / 4095, accuracy: 0.000001)
    }
}

private extension Array where Element == UInt8 {
    func firstIndex(of element: UInt8, startingAt index: Int) -> Int? {
        indices.dropFirst(index).first { self[$0] == element }
    }
}
