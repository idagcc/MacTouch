import Foundation

public enum HIDError: Error, LocalizedError, Equatable {
    case malformedDescriptor(String)
    case unsupportedDescriptor(String)
    case malformedReport(String)
    case unsupportedReport(String)

    public var errorDescription: String? {
        switch self {
        case .malformedDescriptor(let detail): return "Invalid HID descriptor: \(detail)"
        case .unsupportedDescriptor(let detail): return "Unsupported HID layout: \(detail)"
        case .malformedReport(let detail): return "Invalid touch report: \(detail)"
        case .unsupportedReport(let detail): return "Unsupported touch report: \(detail)"
        }
    }
}

/// Whether each input packet describes one contact update or a complete frame.
/// Hybrid packets are assembled separately when Contact Count exceeds packet capacity.
public enum HIDReportFraming: String, Sendable {
    case serialContacts
    case completeFrames
}

/// A deliberately bounded parser for absolute touchscreen Input reports.
/// Unknown fields still consume bits; only a Touch Screen application collection
/// may supply contacts. Keyboard, mouse, touchpad and vendor data are never mapped.
public struct HIDDescriptor: Sendable {
    let layouts: [UInt8: HIDTouchLayout]
    let inputLengths: [UInt8: Int]
    public let usesReportIDs: Bool
    public var reportIDs: [UInt8] { layouts.keys.sorted() }
    public var maximumContactsPerReport: Int { layouts.values.map { $0.contacts.count }.max() ?? 0 }
    public var framing: HIDReportFraming {
        guard let layout = layouts.values.first,
              layout.count == nil, layout.contacts.count == 1,
              layout.contacts[0].identifier != nil else { return .completeFrames }
        // Standard serial reporting uses one Finger + Contact Identifier and no
        // Contact Count. A new packet updates that ID; it does not release other IDs.
        return .serialContacts
    }
    public var summary: String {
        if framing == .serialContacts { return "Standard HID • serial contact updates" }
        let count = maximumContactsPerReport
        return "Standard HID • \(count) contact\(count == 1 ? "" : "s") per report"
    }

    public init(data: Data) throws {
        var parser = HIDDescriptorParser(bytes: Array(data))
        let parsed = try parser.parse()
        layouts = parsed.layouts
        inputLengths = parsed.inputLengths
        usesReportIDs = parsed.usesReportIDs
    }
}

struct HIDField: Sendable {
    let offset: Int
    let size: Int
    let minimum: Int64
    let maximum: Int64
    let item: Int
}

struct HIDContactLayout: Sendable {
    let tip: HIDField
    let x: HIDField
    let y: HIDField
    let identifier: HIDField?
    let confidence: HIDField?
}

struct HIDTouchLayout: Sendable {
    let contacts: [HIDContactLayout]
    let count: HIDField?
    let scanTime: HIDField?
}

private struct HIDUsage: Equatable {
    var page: UInt32
    var usage: UInt32
    static let touchScreen = HIDUsage(page: 0x0D, usage: 0x04)
}

private struct HIDGlobals {
    var usagePage: UInt32 = 0
    var minimum: Int64 = 0
    var maximum: Int64 = 0
    var size = 0
    var count = 0
    var reportID: UInt8 = 0
}

private struct HIDLocals {
    var usages: [HIDUsage] = []
    var rangeMinimum: HIDUsage?
}

private struct HIDCollection {
    var id: Int
    var usage: HIDUsage
    var type: UInt8
}

private struct HIDContactBuilder {
    var tip: [HIDField] = []
    var x: [HIDField] = []
    var y: [HIDField] = []
    var identifier: [HIDField] = []
    var confidence: [HIDField] = []

    func build(multitouch: Bool) throws -> HIDContactLayout {
        guard tip.count == 1, !x.isEmpty, !y.isEmpty else {
            throw HIDError.unsupportedDescriptor("each contact needs Tip Switch, X and Y in the same collection")
        }
        // HID permits a second X/Y value for the bounding-box centre (T/C).
        // Accept that exact arrangement and use the first, the actual touch point.
        guard x.count == y.count, x.count <= 2,
              Set(x.map(\.item)).count == 1, Set(y.map(\.item)).count == 1,
              identifier.count <= 1, confidence.count <= 1 else {
            throw HIDError.unsupportedDescriptor("ambiguous duplicate contact fields")
        }
        guard !multitouch || identifier.count == 1 else {
            throw HIDError.unsupportedDescriptor("multiple contacts require Contact Identifier")
        }
        for axis in [x[0], y[0]] {
            guard axis.maximum > axis.minimum else {
                throw HIDError.unsupportedDescriptor("coordinates need a nonzero logical range")
            }
        }
        guard tip[0].minimum == 0, tip[0].maximum == 1 else {
            throw HIDError.unsupportedDescriptor("Tip Switch must have logical range 0…1")
        }
        if let confidence = confidence.first, confidence.minimum != 0 || confidence.maximum != 1 {
            throw HIDError.unsupportedDescriptor("Confidence must have logical range 0…1")
        }
        if let identifier = identifier.first, identifier.minimum < 0 {
            throw HIDError.unsupportedDescriptor("Contact Identifier must be nonnegative")
        }
        return HIDContactLayout(tip: tip[0], x: x[0], y: y[0], identifier: identifier.first, confidence: confidence.first)
    }
}

private struct HIDReportBuilder {
    var contacts: [Int: HIDContactBuilder] = [:]
    var order: [Int] = []
    var count: HIDField?
    var scanTime: HIDField?
    var applicationID: Int?
}

private struct HIDParsedDescriptor {
    let layouts: [UInt8: HIDTouchLayout]
    let inputLengths: [UInt8: Int]
    let usesReportIDs: Bool
}

private struct HIDDescriptorParser {
    let bytes: [UInt8]
    var cursor = 0
    var globals = HIDGlobals()
    var globalsStack: [HIDGlobals] = []
    var locals = HIDLocals()
    var collections: [HIDCollection] = []
    var nextCollection = 0
    var usesReportIDs = false
    var inputBits: [UInt8: Int] = [:]
    var reports: [UInt8: HIDReportBuilder] = [:]
    var relevantFieldCount = 0

    mutating func parse() throws -> HIDParsedDescriptor {
        guard !bytes.isEmpty, bytes.count <= 65_536 else {
            throw HIDError.malformedDescriptor("empty or excessively large descriptor")
        }
        while cursor < bytes.count {
            let itemOffset = cursor
            let prefix = bytes[cursor]
            cursor += 1
            guard prefix != 0xFE else {
                throw HIDError.unsupportedDescriptor("long items are not supported")
            }
            let size = [0, 1, 2, 4][Int(prefix & 3)]
            guard cursor + size <= bytes.count else {
                throw HIDError.malformedDescriptor("truncated item at byte \(itemOffset)")
            }
            var unsigned: UInt32 = 0
            for i in 0..<size { unsigned |= UInt32(bytes[cursor + i]) << (i * 8) }
            cursor += size
            let signed: Int64
            if size > 0, unsigned & (UInt32(1) << (size * 8 - 1)) != 0 {
                signed = Int64(unsigned) - (Int64(1) << (size * 8))
            } else { signed = Int64(unsigned) }
            let tag = prefix >> 4
            switch (prefix >> 2) & 3 {
            case 0:
                try main(tag: tag, value: unsigned, itemOffset: itemOffset)
                locals = HIDLocals()
            case 1: try global(tag: tag, value: unsigned, signed: signed, size: size)
            case 2: try local(tag: tag, value: unsigned, size: size)
            default: throw HIDError.unsupportedDescriptor("reserved item type")
            }
        }
        guard collections.isEmpty, globalsStack.isEmpty, locals.rangeMinimum == nil else {
            throw HIDError.malformedDescriptor("unclosed collection, global stack or usage range")
        }
        guard !usesReportIDs || inputBits[0] == nil else {
            throw HIDError.malformedDescriptor("numbered and unnumbered input reports cannot be mixed")
        }
        var layouts: [UInt8: HIDTouchLayout] = [:]
        for (id, report) in reports where !report.contacts.isEmpty {
            let multiple = report.contacts.count > 1
            guard report.contacts.count <= 32 else {
                throw HIDError.unsupportedDescriptor("more than 32 contact slots")
            }
            guard !multiple || report.count != nil else {
                throw HIDError.unsupportedDescriptor("parallel multi-touch requires Contact Count")
            }
            let contacts = try report.order.map { try report.contacts[$0]!.build(multitouch: multiple) }
            layouts[id] = HIDTouchLayout(contacts: contacts, count: report.count, scanTime: report.scanTime)
        }
        guard !layouts.isEmpty else {
            throw HIDError.unsupportedDescriptor("no complete absolute Touch Screen input collection")
        }
        guard layouts.count == 1 else {
            throw HIDError.unsupportedDescriptor("contacts split across report IDs need a device-specific frame assembler")
        }
        return HIDParsedDescriptor(layouts: layouts, inputLengths: inputBits.mapValues { ($0 + 7) / 8 }, usesReportIDs: usesReportIDs)
    }

    mutating func global(tag: UInt8, value: UInt32, signed: Int64, size: Int) throws {
        switch tag {
        case 0: globals.usagePage = value
        case 1: globals.minimum = signed
        case 2: globals.maximum = globals.minimum < 0 ? signed : Int64(value)
        case 3...6: break // Physical units do not affect normalized logical coordinates.
        case 7:
            guard value <= 32 else { throw HIDError.unsupportedDescriptor("report fields wider than 32 bits") }
            globals.size = Int(value)
        case 8:
            guard size == 1, value > 0, value <= 255 else { throw HIDError.malformedDescriptor("invalid Report ID") }
            globals.reportID = UInt8(value)
            usesReportIDs = true
        case 9:
            guard value <= 4096 else { throw HIDError.malformedDescriptor("excessive Report Count") }
            globals.count = Int(value)
        case 10:
            guard globalsStack.count < 64 else { throw HIDError.malformedDescriptor("global stack too deep") }
            globalsStack.append(globals)
        case 11:
            guard let saved = globalsStack.popLast() else { throw HIDError.malformedDescriptor("Pop without Push") }
            globals = saved
        default: throw HIDError.unsupportedDescriptor("unknown global item")
        }
    }

    mutating func local(tag: UInt8, value: UInt32, size: Int) throws {
        let usage = size == 4 ? HIDUsage(page: value >> 16, usage: value & 0xFFFF) : HIDUsage(page: globals.usagePage, usage: value)
        switch tag {
        case 0:
            guard locals.usages.count < 4096 else { throw HIDError.malformedDescriptor("too many usages") }
            locals.usages.append(usage)
        case 1:
            guard locals.rangeMinimum == nil else { throw HIDError.malformedDescriptor("nested usage range") }
            locals.rangeMinimum = usage
        case 2:
            guard let lower = locals.rangeMinimum, lower.page == usage.page, lower.usage <= usage.usage,
                  usage.usage - lower.usage < 4096, locals.usages.count + Int(usage.usage - lower.usage) < 4096 else {
                throw HIDError.malformedDescriptor("invalid usage range")
            }
            for id in lower.usage...usage.usage { locals.usages.append(HIDUsage(page: usage.page, usage: id)) }
            locals.rangeMinimum = nil
        case 3...5, 7...9: break // Designator/string metadata.
        case 10: throw HIDError.unsupportedDescriptor("usage delimiters")
        default: throw HIDError.unsupportedDescriptor("unknown local item")
        }
    }

    mutating func main(tag: UInt8, value: UInt32, itemOffset: Int) throws {
        guard locals.rangeMinimum == nil else { throw HIDError.malformedDescriptor("Usage Minimum without Maximum") }
        switch tag {
        case 10:
            guard collections.count < 64, value <= 255 else { throw HIDError.malformedDescriptor("invalid collection") }
            guard let usage = locals.usages.first else { throw HIDError.malformedDescriptor("collection without Usage") }
            collections.append(HIDCollection(id: nextCollection, usage: usage, type: UInt8(value)))
            nextCollection += 1
        case 12:
            guard collections.popLast() != nil else { throw HIDError.malformedDescriptor("End Collection without Collection") }
        case 8:
            guard globals.size > 0, globals.count > 0, !collections.isEmpty else {
                throw HIDError.malformedDescriptor("Input without size, count or collection")
            }
            let offset = inputBits[globals.reportID, default: 0]
            let bitCount = globals.size * globals.count
            guard offset + bitCount <= 65_536 else { throw HIDError.malformedDescriptor("input report too large") }
            inputBits[globals.reportID] = offset + bitCount
            guard value & 1 == 0 else { return } // Constant padding consumes bits.
            guard let app = collections.last(where: { $0.type == 1 }), app.usage == .touchScreen else { return }
            let contactCollection = collections.last(where: { $0.usage.page == 0x0D && [0x20, 0x22].contains($0.usage.usage) }) ?? app
            for index in 0..<globals.count {
                guard !locals.usages.isEmpty else { continue }
                let usage = locals.usages[min(index, locals.usages.count - 1)]
                let isAxis = usage.page == 1 && [0x30, 0x31].contains(usage.usage)
                let isContact = usage.page == 0x0D && [0x42, 0x47, 0x51, 0x54, 0x56].contains(usage.usage)
                guard isAxis || isContact else { continue }
                relevantFieldCount += 1
                guard relevantFieldCount <= 4096 else {
                    throw HIDError.malformedDescriptor("too many touchscreen fields")
                }
                guard value & 2 != 0, value & 4 == 0, value & 0x100 == 0 else {
                    throw HIDError.unsupportedDescriptor("touch fields must be absolute scalar variables")
                }
                let minimum = globals.minimum
                let maximum = globals.maximum
                let representableMinimum: Int64 = minimum < 0 ? -(Int64(1) << (globals.size - 1)) : 0
                let representableMaximum: Int64 = minimum < 0 ? (Int64(1) << (globals.size - 1)) - 1 : (Int64(1) << globals.size) - 1
                guard minimum >= representableMinimum, maximum <= representableMaximum, maximum >= minimum else {
                    throw HIDError.malformedDescriptor("logical range does not fit field")
                }
                let field = HIDField(offset: offset + index * globals.size, size: globals.size,
                                     minimum: minimum, maximum: maximum, item: itemOffset)
                var report = reports[globals.reportID, default: HIDReportBuilder()]
                guard report.applicationID == nil || report.applicationID == app.id else {
                    throw HIDError.unsupportedDescriptor("multiple touchscreen application collections share a report")
                }
                report.applicationID = app.id
                if usage.page == 0x0D, usage.usage == 0x54 {
                    guard report.count == nil, minimum >= 0 else { throw HIDError.unsupportedDescriptor("ambiguous Contact Count") }
                    report.count = field
                } else if usage.page == 0x0D, usage.usage == 0x56 {
                    guard report.scanTime == nil, minimum >= 0 else { throw HIDError.unsupportedDescriptor("ambiguous Scan Time") }
                    report.scanTime = field
                } else {
                    let key = contactCollection.id
                    if report.contacts[key] == nil { report.order.append(key) }
                    var contact = report.contacts[key, default: HIDContactBuilder()]
                    switch (usage.page, usage.usage) {
                    case (1, 0x30): contact.x.append(field)
                    case (1, 0x31): contact.y.append(field)
                    case (0x0D, 0x42): contact.tip.append(field)
                    case (0x0D, 0x47): contact.confidence.append(field)
                    case (0x0D, 0x51): contact.identifier.append(field)
                    default: break
                    }
                    report.contacts[key] = contact
                }
                reports[globals.reportID] = report
            }
        case 9, 11: break // Output and Feature reports use independent bit offsets.
        default: throw HIDError.unsupportedDescriptor("unknown main item")
        }
    }
}
