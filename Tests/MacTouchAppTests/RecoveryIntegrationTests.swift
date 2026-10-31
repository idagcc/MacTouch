import AppKit
import Foundation
import XCTest
import MacTouchCore
@testable import MacTouchApp

private final class TestTouchInput: TouchInputService {
    var onDevices: (([TouchDevice]) -> Void)?
    var onFrame: ((String, TouchFrame) -> Void)?
    var onFailure: ((String, String) -> Void)?
    var onRemoved: ((String) -> Void)?
    var onIdentityInvalidated: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var devices: [TouchDevice] = []
    var requests = 0
    var confirmMode = true

    func start() { onDevices?(devices) }
    func stop() { for device in devices { onRemoved?(device.id) } }
    func rescan() { stop(); start() }
    func resetDecoder(for selectedID: String) {}
    func currentDevices() -> [TouchDevice] { devices }
    func requestMultitouchMode(for selectedID: String) -> String {
        requests += 1
        if let index = devices.firstIndex(where: { $0.id == selectedID }) {
            devices[index].inputModeBefore = 0
            devices[index].inputModeAfter = confirmMode ? 2 : nil
        }
        onDevices?(devices)
        return confirmMode ? "Verified mode 2" : "Temporary feature read failure"
    }

    func disconnect() { stop(); devices = []; onDevices?([]) }
    func connect(_ device: TouchDevice) { devices = [device]; onDevices?(devices) }
}

final class RecoveryIntegrationTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private let savedID = "9589:1025:34799616:interface-0"
    private let fingerprint = ControllerFingerprint(vendorID: 9589, productID: 1025, interfaceNumber: 0, descriptorHash: "known-format")

    override func setUpWithError() throws {
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "MacTouch.AppTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
    }

    private func settings(automatic: Bool = true) -> DeviceSettingsStore {
        let store = DeviceSettingsStore(defaults: defaults, fileURL: directory.appendingPathComponent("settings.json"))
        if store.profile(for: savedID) == nil {
            // Deliberately unavailable display: these tests must never emit
            // real pointer input even though permission checks are stubbed.
            store.saveProfile(DeviceProfile(displayID: "unavailable-test-display", pointer: .init(mapPinchZoom: true),
                automaticReconnect: automatic, restoreMultitouchMode: true, fingerprint: fingerprint), for: savedID)
            store.selectDevice(savedID); store.setEnabled(true)
        }
        return store
    }

    private func device(id: String? = nil, connection: UInt64 = 1) -> TouchDevice {
        var device = TouchDevice(id: id ?? savedID, connectionID: connection, name: "Test controller",
            vendorID: 9589, productID: 1025, transport: "Test", descriptor: Data(), support: "Supported test format", usable: true)
        device.formatSupported = true; device.supportsMultitouchMode = true; device.fingerprint = fingerprint
        return device
    }

    private func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.04)) }

    func testStartupRestoresModeWithoutTurningOffTheSavedEnablePreference() {
        let store = settings()
        let input = TestTouchInput(); input.devices = [device()]
        let model = AppModel(settings: store, hid: input, accessibilityCheck: { true }, inputMonitoringCheck: { true })
        model.notice = "Touch input stopped: prior USB failure"
        model.start(); defer { model.stop() }; drain()
        XCTAssertEqual(input.requests, 1)
        XCTAssertTrue(model.enabled)
        XCTAssertTrue(store.enabled)
        XCTAssertTrue(model.configuration.mapPinchZoom)
        XCTAssertNil(model.notice, "Successful background recovery clears the old controller error.")
        XCTAssertEqual(model.selectedDisplayID, "unavailable-test-display")
        XCTAssertFalse(model.canBridge, "Never redirect a missing saved display to the current screen.")
    }

    func testUSBDisconnectAndDifferentPortReconnectRestoreTheSameSetup() {
        let store = settings()
        let input = TestTouchInput(); input.devices = [device()]
        let model = AppModel(settings: store, hid: input, accessibilityCheck: { true }, inputMonitoringCheck: { true })
        model.start(); defer { model.stop() }; drain()
        input.disconnect(); drain()
        let changedID = "9589:1025:999999:interface-0"
        input.connect(device(id: changedID, connection: 2)); drain(); drain()
        XCTAssertEqual(model.selectedDeviceID, changedID)
        XCTAssertEqual(model.selectedDisplayID, "unavailable-test-display")
        XCTAssertTrue(model.configuration.mapPinchZoom)
        XCTAssertTrue(model.enabled)
        XCTAssertEqual(input.requests, 2)
        XCTAssertEqual(settings().selectedDeviceID, changedID)
    }

    func testManualModeRequestTemporarilyPausesWithoutSavingTouchAsDisabled() {
        let store = settings(automatic: false)
        let input = TestTouchInput(); input.devices = [device()]
        let model = AppModel(settings: store, hid: input, accessibilityCheck: { true }, inputMonitoringCheck: { true })
        model.start(); defer { model.stop() }; drain()
        XCTAssertEqual(input.requests, 0)
        model.requestMultitouchMode()
        XCTAssertEqual(input.requests, 1)
        XCTAssertTrue(model.enabled)
        XCTAssertTrue(settings().enabled)
        XCTAssertTrue(settings().profile(for: savedID)!.restoreMultitouchMode)
        model.enabled = false
        model.requestMultitouchMode()
        XCTAssertFalse(model.enabled, "A deliberately paused controller must stay paused too.")
        XCTAssertFalse(settings().enabled)
    }

    func testFailedRecoveryPreservesSettingsAndDoesNotReenterFromDevicePublish() {
        let store = settings()
        let input = TestTouchInput(); input.devices = [device()]; input.confirmMode = false
        let model = AppModel(settings: store, hid: input, accessibilityCheck: { true }, inputMonitoringCheck: { true })
        model.start(); defer { model.stop() }; drain(); drain()
        XCTAssertEqual(input.requests, 1)
        XCTAssertTrue(model.enabled)
        XCTAssertTrue(settings().profile(for: savedID)!.pointer.mapPinchZoom)
        XCTAssertTrue(model.waitingForLift)
        XCTAssertTrue(model.recoveryStatus.contains("automatically"))
    }

    func testNewModelReloadsTheEditedOptionsEvenWhenControllerIsAbsent() {
        let store = settings()
        let first = AppModel(settings: store, hid: TestTouchInput())
        first.configuration.rotation = 270
        first.configuration.invertY = true
        first.configuration.scrollSpeed = 2.1
        first.automaticReconnect = true
        let restarted = AppModel(settings: settings(), hid: TestTouchInput())
        XCTAssertEqual(restarted.configuration, first.configuration)
        XCTAssertEqual(restarted.selectedDisplayID, first.selectedDisplayID)
        XCTAssertTrue(restarted.configuration.mapPinchZoom)
        XCTAssertTrue(restarted.enabled)
    }

    func testDiagnoseDoesNotRestoreModeOrChangeSavedPreferences() {
        let store = settings()
        let before = try! Data(contentsOf: store.fileURL)
        let input = TestTouchInput(); input.devices = [device()]
        let model = AppModel(settings: store, hid: input, accessibilityCheck: { true }, inputMonitoringCheck: { true }, diagnosticMode: true)
        model.start(); drain(); model.stop()
        XCTAssertEqual(input.requests, 0)
        XCTAssertFalse(model.enabled)
        XCTAssertTrue(store.enabled)
        XCTAssertEqual(try! Data(contentsOf: store.fileURL), before)
    }

    func testNativeControllerWithoutAModeFeatureDoesNotGetStuckRestoring() {
        let store = settings()
        let input = TestTouchInput()
        var native = device(); native.supportsMultitouchMode = false
        input.devices = [native]
        let model = AppModel(settings: store, hid: input, accessibilityCheck: { true }, inputMonitoringCheck: { true })
        model.start(); defer { model.stop() }; drain()
        XCTAssertEqual(input.requests, 0)
        XCTAssertTrue(model.enabled)
        XCTAssertEqual(model.recoveryStatus, "Connected · no controller mode change needed")
    }
}
