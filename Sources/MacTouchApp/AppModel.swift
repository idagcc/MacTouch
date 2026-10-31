import AppKit
import Combine
import ApplicationServices
import IOKit.hidsystem
import ServiceManagement
import MacTouchCore

struct ConnectedDisplay: Identifiable {
    let id: String
    let name: String
    let bounds: CGRect
}

final class AppModel: ObservableObject {
    @Published var devices: [TouchDevice] = []
    @Published var displays: [ConnectedDisplay] = []
    @Published var selectedDeviceID: String {
        didSet {
            resetInput(resetTouchState: true); resetTouchTest(); recovery.reset()
            if !diagnosticMode { checkSettingsSave(settings.selectDevice(selectedDeviceID)) }
            loadProfile(); scheduleRecovery()
        }
    }
    @Published var selectedDisplayID = "" { didSet { resetInput(); saveProfile() } }
    @Published var configuration = PointerConfiguration() {
        didSet {
            resetInput()
            if !loadingProfile && configuration.mapPinchZoom && !restoreMultitouchMode {
                restoreMultitouchMode = true; recovery.reset()
            }
            saveProfile(); scheduleRecovery()
        }
    }
    @Published var enabled: Bool {
        didSet { resetInput(); if !diagnosticMode { checkSettingsSave(settings.setEnabled(enabled)) }; scheduleRecovery() }
    }
    @Published var automaticReconnect = true {
        didSet { if !loadingProfile { recovery.reset(); saveProfile(); scheduleRecovery() } }
    }
    @Published private(set) var recoveryStatus = "Waiting for the saved controller"
    @Published private(set) var applyingDeviceMode = false
    @Published var accessibilityAllowed = false
    @Published var inputAllowed = false
    @Published var loginEnabled = false
    @Published var loginStatus = "Off"
    @Published var serviceStatus = "Starting touchscreen discovery"
    @Published var notice: String?
    @Published var contacts: [TouchContact] = []
    @Published var frameCount = 0
    @Published var waitingForLift = true
    @Published var suspended = false
    @Published var lastTouch = "No touch received yet"
    @Published var touchTesterActive = false { didSet { resetInput(); resetGestureTest() } }
    @Published private(set) var touchTest = TouchTestSession()
    @Published private(set) var gestureTestText = "Place two fingers to test pinch or scroll"
    @Published private(set) var gestureTestScale = 1.0
    let hid: TouchInputService
    private let accessibilityCheck: () -> Bool
    private let inputMonitoringCheck: () -> Bool
    private let settings: DeviceSettingsStore
    private let diagnosticMode: Bool
    private let output = PointerOutput()
    private var engine = PointerEngine()
    private var loadingProfile = false
    private var restoreMultitouchMode = false
    private var profileFingerprint: ControllerFingerprint?
    private var recovery = ControllerRecovery()
    private var recoveryScheduled = false
    private var hasStarted = false
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var lastFrameTime = ProcessInfo.processInfo.systemUptime
    private var lastUIUpdate = 0.0
    private var receivedFrames = 0
    private var touchTestSession = TouchTestSession()
    private var gestureTestEngine = PointerEngine()
    private var pendingGestureText = "Place two fingers to test pinch or scroll"
    private var pendingGestureScale = 1.0
    private var wasAllowed = false
    private var hasActiveInput = false
    private var suspensionReasons: Set<String> = []

    init(settings: DeviceSettingsStore = .init(), hid: TouchInputService = HIDService(),
         accessibilityCheck: @escaping () -> Bool = { AXIsProcessTrusted() && CGPreflightPostEventAccess() },
         inputMonitoringCheck: @escaping () -> Bool = { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted },
         diagnosticMode: Bool = CommandLine.arguments.contains("--diagnose")) {
        self.settings = settings
        self.diagnosticMode = diagnosticMode
        self.hid = hid; self.accessibilityCheck = accessibilityCheck
        self.inputMonitoringCheck = inputMonitoringCheck
        selectedDeviceID = settings.selectedDeviceID
        enabled = diagnosticMode ? false : settings.enabled
        loadProfile()
        hid.onDevices = { [weak self] in self?.devices = $0; self?.scheduleRecovery() }
        hid.onFrame = { [weak self] in self?.receive(id: $0, frame: $1) }
        hid.onFailure = { [weak self] id, error in
            guard let self, id == self.selectedDeviceID else { return }
            self.resetInput(resetTouchState: true)
            self.recovery.disconnected(); self.scheduleRecovery()
            self.notice = "Touch input stopped: \(error) Export diagnostics to add support for this controller."
        }
        hid.onRemoved = { [weak self] id in
            guard let self, id == self.selectedDeviceID else { return }
            self.resetInput(resetTouchState: true)
            self.recovery.disconnected()
            self.recoveryStatus = self.automaticReconnect ? "Waiting to reconnect automatically" : "Controller disconnected"
        }
        hid.onIdentityInvalidated = { [weak self] id in
            guard let self, id == self.selectedDeviceID else { return }
            self.selectedDeviceID = ""
            self.notice = "This controller exposes indistinguishable interfaces. Choose an interface again; automatic reconnect is disabled for this ambiguous identity."
        }
        hid.onStatus = { [weak self] in self?.serviceStatus = $0 }
    }

    var selectedDevice: TouchDevice? { devices.first { $0.id == selectedDeviceID } }
    var selectedDisplay: ConnectedDisplay? { displays.first { $0.id == selectedDisplayID } }
    var canBridge: Bool {
        selectedDevice?.usable == true && selectedDisplay != nil && accessibilityAllowed && inputAllowed
            && !suspended && !touchTesterActive && !applyingDeviceMode
            && (!automaticReconnect || !restoreMultitouchMode || recovery.ready)
    }
    var headline: String {
        if suspended { return "Paused while your Mac is asleep" }
        if touchTesterActive { return "Touch tester · pointer control paused" }
        if devices.isEmpty { return "Connect your touchscreen" }
        if selectedDevice == nil { return "Choose a touch controller" }
        if !inputAllowed { return "Allow Input Monitoring to read touches" }
        if automaticReconnect && restoreMultitouchMode && !recovery.ready { return recoveryStatus }
        if selectedDevice?.usable == false { return "This controller needs a profile" }
        if selectedDisplay == nil { return "Choose the touchscreen display" }
        if !accessibilityAllowed { return "Allow pointer control" }
        if !enabled { return "Ready to enable touch" }
        return waitingForLift ? "Touch, then lift to get started" : "Touch is connected"
    }
    var isRunning: Bool { enabled && canBridge && !waitingForLift }

    func start() {
        if !diagnosticMode { checkSettingsSave(settings.flush()) }
        refreshDisplays(); refreshPermissions(); refreshLogin()
        hid.start()
        hasStarted = true
        scheduleRecovery()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshDisplays() })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.suspensionReasons.insert(name.rawValue)
                self.suspended = true; self.resetInput(resetTouchState: true)
            })
        }
        let resumeEvents: [(Notification.Name, Notification.Name)] = [
            (NSWorkspace.didWakeNotification, NSWorkspace.willSleepNotification),
            (NSWorkspace.screensDidWakeNotification, NSWorkspace.screensDidSleepNotification),
            (NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.sessionDidResignActiveNotification)
        ]
        for (name, reason) in resumeEvents {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.suspensionReasons.remove(reason.rawValue)
                self.suspended = !self.suspensionReasons.isEmpty
                self.resetInput(resetTouchState: true); self.refreshDisplays()
                if !self.suspended { self.hid.rescan() }
            })
        }
        let heartbeat = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(heartbeat, forMode: .common)
        timer = heartbeat
    }

    func stop() {
        hasStarted = false; timer?.invalidate(); resetInput(); hid.stop()
        if !diagnosticMode { checkSettingsSave(settings.flush()) }
    }

    func rescan() { notice = nil; recovery.reset(); resetInput(); refreshPermissions(); refreshDisplays(); hid.rescan(); scheduleRecovery() }

    func resetTouchTest() {
        touchTestSession.reset()
        // Held fingers remain visible; a reset does not imply a physical liftoff.
        if !contacts.isEmpty { touchTestSession.record(TouchFrame(contacts: contacts)) }
        touchTest = touchTestSession
        resetGestureTest()
    }

    private func resetGestureTest() {
        _ = gestureTestEngine.cancel()
        pendingGestureText = "Place two fingers to test pinch or scroll"
        pendingGestureScale = 1
        gestureTestText = pendingGestureText; gestureTestScale = 1
    }

    private func recordGestureTest(_ frame: TouchFrame, timestamp: TimeInterval) {
        guard touchTesterActive else { return }
        var testConfiguration = configuration
        testConfiguration.mapPinchZoom = true
        testConfiguration.twoFingerScroll = true
        let previousIntent = gestureTestEngine.twoFingerIntent
        // Only inspect the resulting actions; this preview never sends them.
        let actions = gestureTestEngine.process(frame: frame,
            bounds: selectedDisplay?.bounds ?? CGRect(x: 0, y: 0, width: 1001, height: 1001),
            configuration: testConfiguration, timestamp: timestamp)
        if previousIntent == nil && frame.contacts.count == 2 { pendingGestureScale = 1 }
        for action in actions {
            if case .mapZoom(_, _, let delta) = action {
                pendingGestureScale = min(8, max(0.125, pendingGestureScale * exp(delta / 400)))
            }
        }
        switch gestureTestEngine.twoFingerIntent {
        case .pinching: pendingGestureText = "Pinch detected"
        case .scrolling: pendingGestureText = "Two-finger scroll detected"
        case .deciding: pendingGestureText = "Move apart to pinch, or slide together to scroll"
        case nil:
            if frame.contacts.isEmpty { pendingGestureText = "All fingers lifted" }
            else if frame.contacts.count == 1 { pendingGestureText = "Add a second finger to test a pinch" }
            else { pendingGestureText = "Lift all fingers, then use exactly two" }
        }
    }

    func requestMultitouchMode() {
        guard let device = selectedDevice else { return }
        applyingDeviceMode = true
        resetInput(resetTouchState: true)
        _ = recovery.shouldAttempt(connection: device.connectionID, now: ProcessInfo.processInfo.systemUptime)
        notice = hid.requestMultitouchMode(for: selectedDeviceID)
        let confirmed = hid.currentDevices().first(where: { $0.id == selectedDeviceID })?.inputModeAfter == 2
        recovery.complete(confirmed: confirmed)
        if confirmed { restoreMultitouchMode = true; saveProfile() }
        applyingDeviceMode = false
        recoveryStatus = confirmed ? "Connected · saved multitouch mode restored" : "Multitouch mode could not be confirmed"
        resetInput(resetTouchState: true)
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openSettings("Privacy_Accessibility")
    }

    func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        openSettings("Privacy_ListenEvent")
    }

    func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }

    func setLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            notice = nil
        } catch { notice = "Could not change launch at login: \(error.localizedDescription). Keep MacTouch in Applications and try again." }
        refreshLogin()
    }

    func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    private func refreshLogin() {
        switch SMAppService.mainApp.status {
        case .enabled: loginEnabled = true; loginStatus = "Starts quietly when you sign in"
        case .requiresApproval: loginEnabled = true; loginStatus = "Allow MacTouch in Login Items"
        case .notFound: loginEnabled = false; loginStatus = "Install in Applications first"
        case .notRegistered: loginEnabled = false; loginStatus = "Off"
        @unknown default: loginEnabled = false; loginStatus = "Unknown system status"
        }
    }

    private func refreshPermissions() {
        accessibilityAllowed = accessibilityCheck()
        let previouslyAllowedInput = inputAllowed
        inputAllowed = inputMonitoringCheck()
        if (wasAllowed && !accessibilityAllowed) || (previouslyAllowedInput && !inputAllowed) { resetInput(resetTouchState: true) }
        if previouslyAllowedInput && !inputAllowed { recovery.disconnected() }
        if hasStarted && !previouslyAllowedInput && inputAllowed { recovery.reset(); hid.rescan() }
        wasAllowed = accessibilityAllowed
    }

    private func refreshDisplays() {
        resetInput()
        displays = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
            let stableID = CFUUIDCreateString(nil, uuid) as String
            return ConnectedDisplay(id: stableID, name: screen.localizedName, bounds: CGDisplayBounds(id))
        }
        // Preserve a missing target; never silently send touches to a different screen.
    }

    private func receive(id: String, frame: TouchFrame) {
        guard id == selectedDeviceID else { return }
        guard !suspended else { hid.resetDecoder(for: id); return }
        let now = ProcessInfo.processInfo.systemUptime
        lastFrameTime = now; receivedFrames += 1
        touchTestSession.record(frame)
        recordGestureTest(frame, timestamp: now)
        // A second finger may arrive within the same UI tick and then stay still.
        // Never throttle contact membership changes; throttle only position updates.
        let changedIDs = Set(contacts.map(\.id)) != Set(frame.contacts.map(\.id))
        if changedIDs || now - lastUIUpdate > 1.0 / 30.0 || frame.contacts.isEmpty {
            contacts = frame.contacts; frameCount = receivedFrames
            touchTest = touchTestSession
            gestureTestText = pendingGestureText; gestureTestScale = pendingGestureScale
            lastTouch = frame.contacts.isEmpty ? "All fingers lifted" : "\(frame.contacts.count) contact\(frame.contacts.count == 1 ? "" : "s") received"
            lastUIUpdate = now
        }
        guard enabled, canBridge, let display = selectedDisplay else { return }
        if waitingForLift {
            if frame.contacts.isEmpty { waitingForLift = false }
            return
        }
        if frame.contacts.isEmpty { output.resetScroll() }
        output.send(engine.process(frame: frame, bounds: display.bounds, configuration: configuration, timestamp: now))
        hasActiveInput = !frame.contacts.isEmpty
    }

    private func resetInput(resetTouchState: Bool = false) {
        output.send(engine.cancel())
        output.resetScroll()
        hasActiveInput = false
        waitingForLift = true
        if resetTouchState {
            hid.resetDecoder(for: selectedDeviceID)
            contacts = []
            touchTestSession.clearContacts()
            touchTest = touchTestSession
            resetGestureTest()
        }
    }

    private func tick() {
        refreshPermissions(); refreshLogin()
        recoverConnection()
        // A failed controller must not leave the system in a held mouse-button state.
        if (hasActiveInput || !contacts.isEmpty) && ProcessInfo.processInfo.systemUptime - lastFrameTime > 10 {
            resetInput(resetTouchState: true)
            lastTouch = "Input timed out. Lift all fingers before touching again."
        }
    }

    private func loadProfile() {
        loadingProfile = true
        let profile = settings.profile(for: selectedDeviceID) ?? DeviceProfile()
        selectedDisplayID = profile.displayID; configuration = profile.pointer
        automaticReconnect = profile.automaticReconnect
        restoreMultitouchMode = profile.restoreMultitouchMode
        profileFingerprint = profile.fingerprint
        loadingProfile = false
    }

    private func saveProfile() {
        guard !diagnosticMode, !loadingProfile, !selectedDeviceID.isEmpty else { return }
        let profile = DeviceProfile(displayID: selectedDisplayID, pointer: configuration,
            automaticReconnect: automaticReconnect, restoreMultitouchMode: restoreMultitouchMode,
            fingerprint: selectedDevice?.fingerprint ?? profileFingerprint)
        checkSettingsSave(settings.saveProfile(profile, for: selectedDeviceID))
    }

    private func checkSettingsSave(_ succeeded: Bool) {
        if !succeeded {
            notice = "Could not save this setup: \(settings.lastError ?? "storage is unavailable"). Keep MacTouch open until storage is available."
        }
    }

    private func scheduleRecovery() {
        guard hasStarted, !diagnosticMode, !loadingProfile, !recoveryScheduled else { return }
        recoveryScheduled = true
        // HID publishes while a feature request is running. Queue recovery
        // rather than reentering a device callback or starting a second write.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.recoveryScheduled = false
            self.recoverConnection()
        }
    }

    private func recoverConnection() {
        guard hasStarted, !diagnosticMode, !loadingProfile, !applyingDeviceMode, !suspended else { return }
        guard let device = selectedDevice else {
            if !selectedDeviceID.isEmpty, let saved = settings.profile(for: selectedDeviceID),
               let replacement = ControllerReconnect.matchingDevice(savedID: selectedDeviceID, profile: saved,
                    connected: devices.filter(\.formatSupported).map { ReconnectCandidate(id: $0.id, fingerprint: $0.fingerprint) }),
               replacement != selectedDeviceID {
                var restored = saved
                restored.fingerprint = devices.first(where: { $0.id == replacement })?.fingerprint ?? saved.fingerprint
                checkSettingsSave(settings.saveProfile(restored, for: replacement))
                selectedDeviceID = replacement
                recoveryStatus = "Controller found · restoring saved setup"
            } else {
                recoveryStatus = automaticReconnect ? "Waiting to reconnect the saved controller" : "Controller disconnected"
            }
            return
        }
        if let fingerprint = device.fingerprint, profileFingerprint != fingerprint {
            profileFingerprint = fingerprint
            saveProfile()
        }
        guard automaticReconnect else { recoveryStatus = "Automatic reconnect is off"; return }
        guard inputAllowed else { recoveryStatus = "Waiting for Input Monitoring permission"; return }
        guard device.formatSupported else { recoveryStatus = "This controller needs a supported touch format"; return }
        let now = ProcessInfo.processInfo.systemUptime
        if restoreMultitouchMode && device.supportsMultitouchMode {
            guard recovery.shouldAttempt(connection: device.connectionID, now: now) else {
                recoveryStatus = recovery.ready ? "Connected · saved setup restored" : "Retrying controller setup automatically"
                return
            }
            applyingDeviceMode = true
            resetInput(resetTouchState: true)
            _ = hid.requestMultitouchMode(for: selectedDeviceID)
            let confirmed = hid.currentDevices().first(where: { $0.id == selectedDeviceID })?.inputModeAfter == 2
            recovery.complete(confirmed: confirmed)
            applyingDeviceMode = false
            resetInput(resetTouchState: true)
            recoveryStatus = confirmed ? "Connected · multitouch and saved setup restored" : "Retrying multitouch setup automatically"
            if confirmed, notice?.hasPrefix("Touch input stopped:") == true { notice = nil }
        } else if !device.usable {
            guard recovery.shouldAttempt(connection: device.connectionID, now: now) else { return }
            recoveryStatus = "Reopening the controller automatically"
            resetInput(resetTouchState: true)
            hid.rescan()
        } else {
            recovery.complete(confirmed: true)
            recoveryStatus = restoreMultitouchMode ? "Connected · no controller mode change needed" : "Connected · saved setup restored"
            if notice?.hasPrefix("Touch input stopped:") == true { notice = nil }
        }
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MacTouch-diagnostics.json"
        panel.title = "Save touchscreen diagnostics"
        panel.message = "Includes controller IDs, report descriptors, display layout and status. No keystrokes, serial numbers or touch history."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try diagnosticsData().write(to: url, options: .atomic)
            notice = "Diagnostics saved to \(url.lastPathComponent)."
        } catch { notice = "Could not save diagnostics: \(error.localizedDescription)" }
    }

    func diagnosticsData() throws -> Data {
        let payload: [String: Any] = [
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.4", "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "accessibility": accessibilityAllowed, "inputMonitoring": inputAllowed,
            "serviceStatus": serviceStatus, "selectedDevice": selectedDeviceID,
            "selectedDisplay": selectedDisplayID, "enabled": enabled,
            "savedEnabled": settings.enabled, "automaticReconnect": automaticReconnect,
            "restoreMultitouchMode": restoreMultitouchMode, "recoveryStatus": recoveryStatus,
            "pointerSettings": ["rotation": configuration.rotation, "invertX": configuration.invertX,
                "invertY": configuration.invertY, "twoFingerScroll": configuration.twoFingerScroll,
                "scrollSpeed": configuration.scrollSpeed, "mapPinchZoom": configuration.mapPinchZoom],
            "touchTest": ["currentContacts": touchTest.currentContacts, "peakContacts": touchTest.peakContacts, "frames": touchTest.frames],
            "devices": hid.currentDevices().map { device -> [String: Any] in [
                "id": device.id, "name": device.name, "vendorID": device.vendorID, "productID": device.productID,
                "transport": device.transport, "support": device.support, "usable": device.usable,
                "reports": device.reports, "error": device.error ?? "",
                "currentContacts": device.currentContacts, "peakContacts": device.peakContacts,
                "framing": device.framing, "modeStatus": device.modeStatus,
                "touchReportIDs": device.touchReportIDs.map(Int.init),
                "inputModeBefore": device.inputModeBefore.map { $0 as Any } ?? NSNull(),
                "inputModeAfter": device.inputModeAfter.map { $0 as Any } ?? NSNull(),
                "reportDescriptorHex": device.descriptor.map { String(format: "%02x", $0) }.joined()
            ] },
            "displays": displays.map { ["id": $0.id, "name": $0.name, "bounds": NSStringFromRect($0.bounds)] }
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }
}
