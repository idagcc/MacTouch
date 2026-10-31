import Foundation

public struct ControllerFingerprint: Codable, Equatable, Sendable {
    public let vendorID: Int
    public let productID: Int
    public let interfaceNumber: Int?
    public let descriptorHash: String

    public init(vendorID: Int, productID: Int, interfaceNumber: Int?, descriptorHash: String) {
        self.vendorID = vendorID; self.productID = productID
        self.interfaceNumber = interfaceNumber; self.descriptorHash = descriptorHash
    }

    /// Legacy profiles did not retain a descriptor fingerprint. Permit migration
    /// only for matching USB IDs and a matching interface when the old ID
    /// recorded one; the caller must also require a single candidate.
    public func matchesLegacyID(_ id: String) -> Bool {
        let parts = id.split(separator: ":")
        guard parts.count == 4, Int(parts[0]) == vendorID, Int(parts[1]) == productID else { return false }
        if parts[3].hasPrefix("session-"), UInt64(parts[3].dropFirst(8)) != nil { return true }
        guard let interfaceNumber else { return false }
        return parts[3] == "interface-\(interfaceNumber)"
    }

    public func matches(_ other: Self) -> Bool {
        guard vendorID == other.vendorID, productID == other.productID, descriptorHash == other.descriptorHash else { return false }
        if let left = interfaceNumber, let right = other.interfaceNumber { return left == right }
        // Missing interface numbers still permit a unique descriptor match.
        return true
    }
}

public struct DeviceProfile: Codable, Equatable, Sendable {
    public var displayID: String
    public var pointer: PointerConfiguration
    public var automaticReconnect: Bool
    public var restoreMultitouchMode: Bool
    public var fingerprint: ControllerFingerprint?

    public init(displayID: String = "", pointer: PointerConfiguration = .init(),
                automaticReconnect: Bool = true, restoreMultitouchMode: Bool = false,
                fingerprint: ControllerFingerprint? = nil) {
        self.displayID = displayID; self.pointer = pointer
        self.automaticReconnect = automaticReconnect
        self.restoreMultitouchMode = restoreMultitouchMode; self.fingerprint = fingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case displayID, pointer, automaticReconnect, restoreMultitouchMode, fingerprint
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        displayID = try values.decodeIfPresent(String.self, forKey: .displayID) ?? ""
        pointer = try values.decodeIfPresent(PointerConfiguration.self, forKey: .pointer) ?? .init()
        automaticReconnect = try values.decodeIfPresent(Bool.self, forKey: .automaticReconnect) ?? true
        // A legacy working map-pinch profile already requires multitouch mode.
        restoreMultitouchMode = try values.decodeIfPresent(Bool.self, forKey: .restoreMultitouchMode) ?? pointer.mapPinchZoom
        fingerprint = try values.decodeIfPresent(ControllerFingerprint.self, forKey: .fingerprint)
    }
}

/// An atomic, versioned settings file is the source of truth. UserDefaults is
/// retained as a migration source and compatibility mirror, not relied upon
/// as the only copy of a kiosk's setup.
public final class DeviceSettingsStore {
    private struct Snapshot: Codable {
        var version = 1
        var selectedDeviceID: String
        var enabled: Bool
        var profiles: [String: DeviceProfile]
    }

    public static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacTouch", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    private let defaults: UserDefaults
    public let fileURL: URL
    public var backupURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("settings.previous.json") }
    private var snapshot: Snapshot
    public private(set) var lastError: String?
    public private(set) var recoveredFromBackup = false

    public var selectedDeviceID: String { snapshot.selectedDeviceID }
    public var enabled: Bool { snapshot.enabled }
    public var profiles: [String: DeviceProfile] { snapshot.profiles }

    public init(defaults: UserDefaults = .standard, fileURL: URL = DeviceSettingsStore.defaultFileURL) {
        self.defaults = defaults; self.fileURL = fileURL
        let decoder = JSONDecoder()
        func read(_ url: URL) -> Snapshot? {
            guard let data = try? Data(contentsOf: url), let value = try? decoder.decode(Snapshot.self, from: data), value.version == 1 else { return nil }
            return value
        }
        if let saved = read(fileURL) { snapshot = saved; return }
        let previous = fileURL.deletingLastPathComponent().appendingPathComponent("settings.previous.json")
        if let saved = read(previous) { snapshot = saved; recoveredFromBackup = true; return }

        var profiles: [String: DeviceProfile] = [:]
        if let data = defaults.data(forKey: "deviceProfiles"),
           let objects = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            // One damaged old profile must not discard every other controller.
            for (id, object) in objects {
                guard let dictionary = object as? [String: Any],
                      let encoded = try? JSONSerialization.data(withJSONObject: dictionary),
                      let profile = try? decoder.decode(DeviceProfile.self, from: encoded) else { continue }
                profiles[id] = profile
            }
        }
        snapshot = Snapshot(selectedDeviceID: defaults.string(forKey: "selectedDevice") ?? "",
                            enabled: defaults.bool(forKey: "enabled"), profiles: profiles)
    }

    public func profile(for id: String) -> DeviceProfile? { snapshot.profiles[id] }

    @discardableResult public func selectDevice(_ id: String) -> Bool {
        snapshot.selectedDeviceID = id
        return flush()
    }

    @discardableResult public func setEnabled(_ enabled: Bool) -> Bool {
        snapshot.enabled = enabled
        return flush()
    }

    @discardableResult public func saveProfile(_ profile: DeviceProfile, for id: String) -> Bool {
        guard !id.isEmpty else { return true }
        snapshot.profiles[id] = profile
        return flush()
    }

    @discardableResult public func flush() -> Bool {
        do {
            let data = try JSONEncoder().encode(snapshot)
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Keep the last valid file, and never replace a good backup with a
            // corrupt primary file during recovery.
            if let old = try? Data(contentsOf: fileURL),
               let value = try? JSONDecoder().decode(Snapshot.self, from: old), value.version == 1 {
                try old.write(to: backupURL, options: .atomic)
            }
            try data.write(to: fileURL, options: .atomic)
            defaults.set(snapshot.selectedDeviceID, forKey: "selectedDevice")
            defaults.set(snapshot.enabled, forKey: "enabled")
            defaults.set(try JSONEncoder().encode(snapshot.profiles), forKey: "deviceProfiles")
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}

public struct ReconnectCandidate: Equatable, Sendable {
    public let id: String
    public let fingerprint: ControllerFingerprint?
    public init(id: String, fingerprint: ControllerFingerprint?) { self.id = id; self.fingerprint = fingerprint }
}

public enum ControllerReconnect {
    /// Exact saved identity wins. Across ports, only a single matching
    /// controller may inherit the selected profile; identical devices remain
    /// unresolved instead of sending touches to an arbitrary display.
    public static func matchingDevice(savedID: String, profile: DeviceProfile,
                                      connected: [ReconnectCandidate]) -> String? {
        guard profile.automaticReconnect else { return nil }
        if connected.contains(where: { $0.id == savedID }) { return savedID }
        let matches = connected.filter { candidate in
            guard let identity = candidate.fingerprint else { return false }
            if let saved = profile.fingerprint { return saved.matches(identity) }
            return identity.matchesLegacyID(savedID)
        }
        return matches.count == 1 ? matches[0].id : nil
    }
}

public struct ControllerRecovery: Sendable {
    private var connection: UInt64?
    private var attempts = 0
    private var nextAttempt: TimeInterval = 0
    public private(set) var ready = false

    public init() {}
    public mutating func reset() { self = .init() }
    public mutating func disconnected() { ready = false }

    public mutating func shouldAttempt(connection: UInt64, now: TimeInterval) -> Bool {
        guard now.isFinite, now >= 0 else { return false }
        if self.connection != connection { reset(); self.connection = connection }
        guard !ready, now >= nextAttempt else { return false }
        attempts += 1
        nextAttempt = now + min(30, pow(2, Double(min(attempts - 1, 5))))
        return true
    }

    public mutating func complete(confirmed: Bool) { ready = confirmed }
}
