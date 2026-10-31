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

private struct DeviceProfile: Codable {
    var displayID = ""
    var pointer = PointerConfiguration()
}

final class AppModel: ObservableObject {
    @Published var devices: [TouchDevice] = []
    @Published var displays: [ConnectedDisplay] = []
    @Published var selectedDeviceID: String {
        didSet { resetInput(); defaults.set(selectedDeviceID, forKey: "selectedDevice"); loadProfile() }
    }
    @Published var selectedDisplayID = "" { didSet { resetInput(); saveProfile() } }
    @Published var configuration = PointerConfiguration() { didSet { resetInput(); saveProfile() } }
    @Published var enabled: Bool { didSet { resetInput(); defaults.set(enabled, forKey: "enabled") } }
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
    let hid = HIDService()
    private let defaults = UserDefaults.standard
    private let output = PointerOutput()
    private var engine = PointerEngine()
    private var profiles: [String: DeviceProfile] = [:]
    private var loadingProfile = false
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var lastFrameTime = ProcessInfo.processInfo.systemUptime
    private var lastUIUpdate = 0.0
    private var receivedFrames = 0
    private var wasAllowed = false
    private var hasActiveInput = false
    private var suspensionReasons: Set<String> = []

    init() {
        selectedDeviceID = UserDefaults.standard.string(forKey: "selectedDevice") ?? ""
        enabled = CommandLine.arguments.contains("--diagnose") ? false : UserDefaults.standard.bool(forKey: "enabled")
        if let data = defaults.data(forKey: "deviceProfiles"),
           let saved = try? JSONDecoder().decode([String: DeviceProfile].self, from: data) { profiles = saved }
        loadProfile()
        hid.onDevices = { [weak self] in self?.devices = $0 }
        hid.onFrame = { [weak self] in self?.receive(id: $0, frame: $1) }
        hid.onFailure = { [weak self] id, error in
            guard let self, id == self.selectedDeviceID else { return }
            self.resetInput(); self.notice = "Touch input stopped: \(error) Export diagnostics to add support for this controller."
        }
        hid.onRemoved = { [weak self] id in
            guard let self, id == self.selectedDeviceID else { return }
            self.resetInput(); self.contacts = []
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
    var canBridge: Bool { selectedDevice?.usable == true && selectedDisplay != nil && accessibilityAllowed && !suspended }
    var headline: String {
        if suspended { return "Paused while your Mac is asleep" }
        if devices.isEmpty { return "Connect your touchscreen" }
        if selectedDevice == nil { return "Choose a touch controller" }
        if selectedDevice?.usable == false { return "This controller needs a profile" }
        if selectedDisplay == nil { return "Choose the touchscreen display" }
        if !accessibilityAllowed { return "Allow pointer control" }
        if !enabled { return "Ready to enable touch" }
        return waitingForLift ? "Touch, then lift to get started" : "Touch is connected"
    }
    var isRunning: Bool { enabled && canBridge && !waitingForLift }

    func start() {
        refreshDisplays(); refreshPermissions(); refreshLogin()
        hid.start()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshDisplays() })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.suspensionReasons.insert(name.rawValue)
                self.suspended = true; self.resetInput()
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
                self.resetInput(); self.refreshDisplays()
                if !self.suspended { self.hid.rescan() }
            })
        }
        let heartbeat = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(heartbeat, forMode: .common)
        timer = heartbeat
    }

    func stop() { timer?.invalidate(); resetInput(); hid.stop() }

    func rescan() { notice = nil; resetInput(); refreshPermissions(); refreshDisplays(); hid.rescan() }

    func requestMultitouchMode() {
        enabled = false
        notice = hid.requestMultitouchMode(for: selectedDeviceID)
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
        accessibilityAllowed = AXIsProcessTrusted() && CGPreflightPostEventAccess()
        let previouslyAllowedInput = inputAllowed
        inputAllowed = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if (wasAllowed && !accessibilityAllowed) || (previouslyAllowedInput && !inputAllowed) { resetInput() }
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
        let now = ProcessInfo.processInfo.systemUptime
        lastFrameTime = now; receivedFrames += 1
        if now - lastUIUpdate > 1.0 / 30.0 || frame.contacts.isEmpty {
            contacts = frame.contacts; frameCount = receivedFrames
            lastTouch = frame.contacts.isEmpty ? "All fingers lifted" : "\(frame.contacts.count) contact\(frame.contacts.count == 1 ? "" : "s") received"
            lastUIUpdate = now
        }
        guard enabled, canBridge, let display = selectedDisplay else { return }
        if waitingForLift {
            if frame.contacts.isEmpty { waitingForLift = false }
            return
        }
        output.send(engine.process(frame: frame, bounds: display.bounds, configuration: configuration))
        hasActiveInput = !frame.contacts.isEmpty
    }

    private func resetInput() {
        output.send(engine.cancel())
        output.resetScroll()
        hasActiveInput = false
        waitingForLift = true
    }

    private func tick() {
        refreshPermissions(); refreshLogin()
        // A failed controller must not leave the system in a held mouse-button state.
        if hasActiveInput && ProcessInfo.processInfo.systemUptime - lastFrameTime > 10 {
            resetInput(); contacts = []
        }
    }

    private func loadProfile() {
        loadingProfile = true
        let profile = profiles[selectedDeviceID] ?? DeviceProfile()
        selectedDisplayID = profile.displayID; configuration = profile.pointer
        loadingProfile = false
    }

    private func saveProfile() {
        guard !loadingProfile, !selectedDeviceID.isEmpty else { return }
        profiles[selectedDeviceID] = DeviceProfile(displayID: selectedDisplayID, pointer: configuration)
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: "deviceProfiles") }
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
            "appVersion": "0.1.0", "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "accessibility": accessibilityAllowed, "inputMonitoring": inputAllowed,
            "serviceStatus": serviceStatus, "selectedDevice": selectedDeviceID,
            "selectedDisplay": selectedDisplayID, "enabled": enabled,
            "devices": devices.map { device -> [String: Any] in [
                "id": device.id, "name": device.name, "vendorID": device.vendorID, "productID": device.productID,
                "transport": device.transport, "support": device.support, "usable": device.usable,
                "reports": device.reports, "error": device.error ?? "",
                "reportDescriptorHex": device.descriptor.map { String(format: "%02x", $0) }.joined()
            ] },
            "displays": displays.map { ["id": $0.id, "name": $0.name, "bounds": NSStringFromRect($0.bounds)] }
        ]
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }
}
