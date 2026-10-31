import Foundation

/// Measurements from decoded sensor frames. Simulation owns separate view state.
public struct TouchTestSession: Equatable, Sendable {
    public private(set) var currentContacts = 0
    public private(set) var peakContacts = 0
    public private(set) var frames = 0

    public init() {}

    /// Record every frame before UI throttling, including brief multi-contact frames.
    public mutating func record(_ frame: TouchFrame) {
        currentContacts = frame.contacts.count
        peakContacts = max(peakContacts, currentContacts)
        frames += 1
    }

    /// Disconnects and timeouts clear active contacts without erasing measurements.
    public mutating func clearContacts() { currentContacts = 0 }

    public mutating func reset() { self = TouchTestSession() }
}
