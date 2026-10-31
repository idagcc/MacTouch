import Foundation
import XCTest
@testable import MacTouchCore

final class DeviceSettingsTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private let savedID = "9589:1025:34799616:interface-0"
    private let identity = ControllerFingerprint(vendorID: 9589, productID: 1025, interfaceNumber: 0, descriptorHash: "controller-report-format")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "MacTouch.SettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
    }

    private func store() -> DeviceSettingsStore {
        DeviceSettingsStore(defaults: defaults, fileURL: directory.appendingPathComponent("settings.json"))
    }

    private var profile: DeviceProfile {
        DeviceProfile(displayID: "saved-display", pointer: .init(rotation: 90, invertX: true, scrollSpeed: 2.2, mapPinchZoom: true),
                      automaticReconnect: true, restoreMultitouchMode: true, fingerprint: identity)
    }

    func testEverySettingAndEnablePreferenceSurvivesANewStoreInstance() {
        let first = store()
        XCTAssertTrue(first.saveProfile(profile, for: savedID))
        XCTAssertTrue(first.selectDevice(savedID))
        XCTAssertTrue(first.setEnabled(true))
        let restarted = store()
        XCTAssertEqual(restarted.profile(for: savedID), profile)
        XCTAssertEqual(restarted.selectedDeviceID, savedID)
        XCTAssertTrue(restarted.enabled)
    }

    func testMigratesLegacyPinchProfileWithoutResettingMapping() throws {
        defaults.set(savedID, forKey: "selectedDevice")
        defaults.set(true, forKey: "enabled")
        let legacy = [savedID: ["displayID": "old-display", "pointer": ["rotation": 270, "invertY": true, "mapPinchZoom": true, "scrollSpeed": 1.7]]] as [String: Any]
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "deviceProfiles")
        let migrated = store()
        let restored = try XCTUnwrap(migrated.profile(for: savedID))
        XCTAssertEqual(restored.displayID, "old-display")
        XCTAssertEqual(restored.pointer.rotation, 270)
        XCTAssertTrue(restored.pointer.invertY)
        XCTAssertTrue(restored.pointer.mapPinchZoom)
        XCTAssertEqual(restored.pointer.scrollSpeed, 1.7)
        XCTAssertTrue(restored.automaticReconnect)
        XCTAssertTrue(restored.restoreMultitouchMode)
        XCTAssertTrue(migrated.flush())
        XCTAssertEqual(store().profile(for: savedID), restored)
    }

    func testOneDamagedLegacyProfileDoesNotDiscardAHealthyController() throws {
        let healthy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
        defaults.set(try JSONSerialization.data(withJSONObject: [savedID: healthy, "bad-controller": "not a profile"]), forKey: "deviceProfiles")
        XCTAssertEqual(store().profile(for: savedID), profile)
    }

    func testAtomicFileWinsOverStalePreferenceValues() {
        let first = store()
        XCTAssertTrue(first.saveProfile(profile, for: savedID))
        XCTAssertTrue(first.setEnabled(true))
        defaults.set(false, forKey: "enabled")
        defaults.removeObject(forKey: "deviceProfiles")
        let restarted = store()
        XCTAssertTrue(restarted.enabled)
        XCTAssertEqual(restarted.profile(for: savedID), profile)
    }

    func testCorruptPrimaryRecoversTheLastGoodSetupWithoutErasingBackup() throws {
        let first = store()
        first.saveProfile(profile, for: savedID); first.selectDevice(savedID); first.setEnabled(true)
        XCTAssertTrue(first.flush())
        try Data("interrupted file".utf8).write(to: first.fileURL)
        let recovered = store()
        XCTAssertTrue(recovered.recoveredFromBackup)
        XCTAssertEqual(recovered.profile(for: savedID), profile)
        XCTAssertTrue(recovered.enabled)
        XCTAssertTrue(recovered.flush())
        XCTAssertEqual(store().profile(for: savedID), profile)
    }

    func testSaveFailureIsReportedRatherThanSilentlyClaimingPersistence() throws {
        let blocker = directory.appendingPathComponent("a-file")
        try Data().write(to: blocker)
        let failed = DeviceSettingsStore(defaults: defaults, fileURL: blocker.appendingPathComponent("settings.json"))
        XCTAssertFalse(failed.saveProfile(profile, for: savedID))
        XCTAssertNotNil(failed.lastError)
    }

    func testEncodingFailureKeepsThePreviouslySavedFile() {
        let first = store()
        XCTAssertTrue(first.saveProfile(profile, for: savedID))
        var invalid = profile; invalid.pointer.scrollSpeed = .nan
        XCTAssertFalse(first.saveProfile(invalid, for: savedID))
        XCTAssertEqual(store().profile(for: savedID), profile)
    }

    func testReconnectAcrossUSBPortsUsesTheRememberedProfile() {
        let next = ReconnectCandidate(id: "9589:1025:another-port:interface-0", fingerprint: identity)
        XCTAssertEqual(ControllerReconnect.matchingDevice(savedID: savedID, profile: profile, connected: [next]), next.id)
    }

    func testExactPortIdentityWinsOverAnotherIdenticalController() {
        let connected = [ReconnectCandidate(id: savedID, fingerprint: identity), ReconnectCandidate(id: "second-device", fingerprint: identity)]
        XCTAssertEqual(ControllerReconnect.matchingDevice(savedID: savedID, profile: profile, connected: connected), savedID)
    }

    func testAmbiguousIdenticalControllersAreNotGuessed() {
        let connected = [ReconnectCandidate(id: "first-device", fingerprint: identity), ReconnectCandidate(id: "second-device", fingerprint: identity)]
        XCTAssertNil(ControllerReconnect.matchingDevice(savedID: savedID, profile: profile, connected: connected))
    }

    func testDifferentDescriptorOrInterfaceCannotInheritTheSavedDisplay() {
        let wrongFormat = ControllerFingerprint(vendorID: 9589, productID: 1025, interfaceNumber: 0, descriptorHash: "different")
        let wrongInterface = ControllerFingerprint(vendorID: 9589, productID: 1025, interfaceNumber: 1, descriptorHash: identity.descriptorHash)
        for wrong in [wrongFormat, wrongInterface] {
            XCTAssertNil(ControllerReconnect.matchingDevice(savedID: savedID, profile: profile, connected: [.init(id: "new-port", fingerprint: wrong)]))
        }
    }

    func testLegacyIdentityCanMigrateOnlyToOneMatchingInterface() {
        var legacy = profile; legacy.fingerprint = nil
        XCTAssertEqual(ControllerReconnect.matchingDevice(savedID: savedID, profile: legacy, connected: [.init(id: "new-port", fingerprint: identity)]), "new-port")
        XCTAssertEqual(ControllerReconnect.matchingDevice(savedID: "9589:1025:0:session-123", profile: legacy, connected: [.init(id: "new-port", fingerprint: identity)]), "new-port")
        XCTAssertNil(ControllerReconnect.matchingDevice(savedID: "123:456:0:session-123", profile: legacy, connected: [.init(id: "new-port", fingerprint: identity)]))
    }

    func testMissingInterfaceNumberCanReconnectByUniqueDescriptorWithoutGuessingBetweenDuplicates() {
        var saved = profile
        saved.fingerprint = ControllerFingerprint(vendorID: 9589, productID: 1025, interfaceNumber: nil, descriptorHash: identity.descriptorHash)
        XCTAssertEqual(ControllerReconnect.matchingDevice(savedID: "old-session", profile: saved, connected: [.init(id: "new-session", fingerprint: identity)]), "new-session")
        XCTAssertNil(ControllerReconnect.matchingDevice(savedID: "old-session", profile: saved, connected: [.init(id: "a", fingerprint: identity), .init(id: "b", fingerprint: identity)]))
    }

    func testReconnectCanBeTurnedOffAndThatChoicePersists() {
        var manual = profile; manual.automaticReconnect = false
        XCTAssertTrue(store().saveProfile(manual, for: savedID))
        XCTAssertFalse(store().profile(for: savedID)!.automaticReconnect)
        XCTAssertNil(ControllerReconnect.matchingDevice(savedID: savedID, profile: manual, connected: [.init(id: "new-port", fingerprint: identity)]))
    }

    func testRecoveryRetriesWithBackoffAndStopsAfterConfirmation() {
        var recovery = ControllerRecovery()
        XCTAssertTrue(recovery.shouldAttempt(connection: 10, now: 0))
        XCTAssertFalse(recovery.shouldAttempt(connection: 10, now: 0.5))
        XCTAssertTrue(recovery.shouldAttempt(connection: 10, now: 1))
        XCTAssertFalse(recovery.shouldAttempt(connection: 10, now: 2.9))
        XCTAssertTrue(recovery.shouldAttempt(connection: 10, now: 3))
        recovery.complete(confirmed: true)
        XCTAssertFalse(recovery.shouldAttempt(connection: 10, now: 20))
        recovery.disconnected()
        XCTAssertTrue(recovery.shouldAttempt(connection: 10, now: 21))
    }

    func testNewPhysicalConnectionRetriesImmediatelyAndInvalidTimeDoesNot() {
        var recovery = ControllerRecovery()
        XCTAssertFalse(recovery.shouldAttempt(connection: 10, now: .nan))
        XCTAssertTrue(recovery.shouldAttempt(connection: 10, now: 1))
        XCTAssertTrue(recovery.shouldAttempt(connection: 11, now: 1.01))
    }

    func testRepeatedFailuresBackOffToThirtySecondsWithoutGivingUp() {
        var recovery = ControllerRecovery()
        for due in [0.0, 1, 3, 7, 15, 31, 61, 91] {
            if due > 0 { XCTAssertFalse(recovery.shouldAttempt(connection: 10, now: due - 0.01)) }
            XCTAssertTrue(recovery.shouldAttempt(connection: 10, now: due))
            recovery.complete(confirmed: false)
        }
        XCTAssertFalse(recovery.shouldAttempt(connection: 10, now: 120.9))
        XCTAssertTrue(recovery.shouldAttempt(connection: 10, now: 121))
    }
}
