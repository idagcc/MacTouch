import Foundation

public struct TouchContact: Equatable, Sendable {
    public let id: Int
    public let x: Double
    public let y: Double

    public init(id: Int, x: Double, y: Double) {
        self.id = id
        self.x = x
        self.y = y
    }
}

public struct TouchFrame: Equatable, Sendable {
    public let contacts: [TouchContact]

    public init(contacts: [TouchContact]) { self.contacts = contacts }
}

extension HIDDescriptor {
    /// Decodes one complete input report, including its ID byte when numbered.
    /// Use HIDReportDecoder to retain serial contacts or assemble hybrid frames.
    public func decode(report: Data) throws -> TouchFrame? {
        guard let packet = try inputReport(report: report) else { return nil }
        let reportedCount = try packet.contactCount
        if let count = reportedCount, count > packet.layout.contacts.count {
            throw HIDError.unsupportedReport("\(count) contacts exceed \(packet.layout.contacts.count) report slots; use guarded hybrid frame assembly")
        }
        if reportedCount == 0 {
            // A zero-count packet with active slots can be a hybrid continuation,
            // so a stateless caller must never interpret it as a complete frame.
            for slot in packet.layout.contacts where try packet.value(slot.tip) != 0 {
                throw HIDError.unsupportedReport("zero-count continuation packet requires frame assembly")
            }
            return TouchFrame(contacts: [])
        }
        let entries = try packet.entries(count: reportedCount ?? packet.layout.contacts.count)
        return TouchFrame(contacts: entries.compactMap(\.contact))
    }

    fileprivate func inputReport(report: Data) throws -> HIDInputReport? {
        let bytes = Array(report)
        guard !bytes.isEmpty else { throw HIDError.malformedReport("empty report") }
        let id = usesReportIDs ? bytes[0] : 0
        guard let layout = layouts[id] else { return nil }
        let payloadStart = usesReportIDs ? 1 : 0
        let expected = inputLengths[id, default: 0] + payloadStart
        guard bytes.count >= expected else {
            throw HIDError.malformedReport("report \(id) needs \(expected) bytes, received \(bytes.count)")
        }
        // USB stacks may provide zero padding to the endpoint packet size.
        guard bytes.dropFirst(expected).allSatisfy({ $0 == 0 }) else {
            throw HIDError.malformedReport("unexpected data beyond declared report length")
        }
        return HIDInputReport(id: id, bytes: bytes, payloadStart: payloadStart, layout: layout)
    }
}

private struct HIDContactEntry {
    let id: Int
    let contact: TouchContact?
}

private struct HIDInputReport {
    let id: UInt8
    let bytes: [UInt8]
    let payloadStart: Int
    let layout: HIDTouchLayout

    var contactCount: Int? { get throws { try layout.count.map { Int(try value($0)) } } }
    var scanTime: Int64? { get throws { try layout.scanTime.map { try value($0) } } }

    func value(_ field: HIDField) throws -> Int64 {
        var raw: UInt64 = 0
        for bit in 0..<field.size {
            let position = field.offset + bit
            let byte = bytes[payloadStart + position / 8]
            if byte & (1 << (position % 8)) != 0 { raw |= UInt64(1) << bit }
        }
        let result: Int64
        if field.minimum < 0, raw & (UInt64(1) << (field.size - 1)) != 0 {
            result = Int64(raw) - (Int64(1) << field.size)
        } else { result = Int64(raw) }
        guard result >= field.minimum, result <= field.maximum else {
            throw HIDError.malformedReport("value outside descriptor logical range")
        }
        return result
    }

    func entries(count: Int) throws -> [HIDContactEntry] {
        var entries: [HIDContactEntry] = []
        var identifiers = Set<Int>()
        for (index, slot) in layout.contacts.prefix(count).enumerated() {
            let identifier = try slot.identifier.map { Int(try value($0)) } ?? index
            guard identifiers.insert(identifier).inserted else {
                throw HIDError.malformedReport("duplicate Contact Identifier in frame")
            }
            let tip = try value(slot.tip)
            let confidence = try slot.confidence.map { try value($0) } ?? 1
            if tip == 0 || confidence == 0 {
                // Liftoff and rejected contacts still consume reported slots.
                entries.append(HIDContactEntry(id: identifier, contact: nil))
                continue
            }
            let x = Double(try value(slot.x) - slot.x.minimum) / Double(slot.x.maximum - slot.x.minimum)
            let y = Double(try value(slot.y) - slot.y.minimum) / Double(slot.y.maximum - slot.y.minimum)
            entries.append(HIDContactEntry(id: identifier, contact: TouchContact(id: identifier, x: x, y: y)))
        }
        return entries
    }
}

/// Per-device decoding of standard serial, parallel and hybrid touch reports.
///
/// The count/offset algorithm is adapted from MIT-licensed Touch-Up's
/// StoreInputValue / DispatchTouches at commit
/// 59a4fd28ae939dafb2f4ad9df9b00e959b40eada (Sebastian Hueber, 2024).
/// See ThirdParty/Touch-Up/LICENSE and NOTICE.md. This Swift adaptation adds
/// scan-time consistency, a monotonic deadline, identifier checks and hard caps.
/// No IOKit queues, private CGEvent fields or cursor code are imported.
public struct HIDReportDecoder: Sendable {
    public let descriptor: HIDDescriptor
    public private(set) var usesHybridFrames = false
    public var usesSerialContacts: Bool { descriptor.framing == .serialContacts }
    public var isAssemblingFrame: Bool { pending != nil }

    private struct Pending: Sendable {
        let reportID: UInt8
        let scanTime: Int64
        let startedAt: TimeInterval
        let expected: Int
        var received = 0
        var identifiers = Set<Int>()
        var contacts: [TouchContact] = []
    }
    private var pending: Pending?
    private var serialContacts: [Int: TouchContact] = [:]
    private var lastTimestamp: TimeInterval?
    private let maximumContacts = 32
    private let frameDeadline: TimeInterval = 0.050

    public init(descriptor: HIDDescriptor) { self.descriptor = descriptor }

    public mutating func reset() {
        pending = nil
        serialContacts.removeAll()
        lastTimestamp = nil
        usesHybridFrames = false
    }

    /// nil means a continuation is incomplete or the report is unrelated.
    /// The deadline is checked on receipt; the app must also release pointer
    /// state when a disconnected or silent device stops delivering frames.
    /// On any error, all assembly state is cleared before throwing.
    public mutating func decode(report: Data, timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> TouchFrame? {
        do {
            guard let packet = try descriptor.inputReport(report: report) else { return nil }
            guard timestamp.isFinite, timestamp >= 0,
                  lastTimestamp.map({ timestamp >= $0 }) ?? true else {
                throw HIDError.malformedReport("invalid or non-monotonic receive time")
            }
            lastTimestamp = timestamp
            if usesSerialContacts {
                // Serial HID packets are per-contact changes, not frame snapshots.
                // Retain each stable ID until its explicit Tip/Confidence release.
                // The host must call reset() on disconnect, mode change or watchdog
                // timeout so an interrupted stream cannot carry contacts into a retry.
                let entry = try packet.entries(count: 1)[0]
                if let contact = entry.contact {
                    guard serialContacts[entry.id] != nil || serialContacts.count < maximumContacts else {
                        throw HIDError.unsupportedReport("serial stream exceeds the 32-contact limit")
                    }
                    serialContacts[entry.id] = contact
                } else {
                    serialContacts.removeValue(forKey: entry.id)
                }
                return TouchFrame(contacts: serialContacts.values.sorted { $0.id < $1.id })
            }
            let count = try packet.contactCount
            if var frame = pending {
                guard timestamp - frame.startedAt <= frameDeadline else {
                    throw HIDError.malformedReport("hybrid frame exceeded its 50 ms deadline")
                }
                guard packet.id == frame.reportID, count == 0, try packet.scanTime == frame.scanTime else {
                    throw HIDError.malformedReport("interrupted hybrid frame or mismatched Scan Time")
                }
                let remaining = frame.expected - frame.received
                let number = min(remaining, packet.layout.contacts.count)
                try append(packet.entries(count: number), to: &frame)
                if frame.received == frame.expected {
                    pending = nil
                    return TouchFrame(contacts: frame.contacts)
                }
                pending = frame
                return nil
            }
            if let count, count > packet.layout.contacts.count {
                guard count <= maximumContacts else {
                    throw HIDError.unsupportedReport("hybrid frame exceeds the 32-contact limit")
                }
                guard let scanTime = try packet.scanTime,
                      packet.layout.contacts.allSatisfy({ $0.identifier != nil }) else {
                    throw HIDError.unsupportedReport("hybrid reports require Scan Time and Contact Identifier for safe assembly")
                }
                var frame = Pending(reportID: packet.id, scanTime: scanTime, startedAt: timestamp, expected: count)
                try append(packet.entries(count: packet.layout.contacts.count), to: &frame)
                pending = frame
                usesHybridFrames = true
                return nil
            }
            return try descriptor.decode(report: report)
        } catch {
            reset()
            throw error
        }
    }

    private func append(_ entries: [HIDContactEntry], to frame: inout Pending) throws {
        for entry in entries {
            guard frame.identifiers.insert(entry.id).inserted else {
                throw HIDError.malformedReport("Contact Identifier repeated across hybrid packets")
            }
            if let contact = entry.contact { frame.contacts.append(contact) }
        }
        frame.received += entries.count
    }
}
