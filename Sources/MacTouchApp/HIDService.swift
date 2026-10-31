import Foundation
import IOKit
import IOKit.hid
import MacTouchCore

struct TouchDevice: Identifiable {
    var id: String
    let name: String
    let vendorID: Int
    let productID: Int
    let transport: String
    let descriptor: Data
    var support: String
    var usable: Bool
    var reports: Int = 0
    var error: String?
    var usbID: String { String(format: "%04X:%04X", vendorID, productID) }
}

/// Run-loop confined to the main thread. Only touchscreen application collections match.
final class HIDService {
    var onDevices: (([TouchDevice]) -> Void)?
    var onFrame: ((String, TouchFrame) -> Void)?
    var onFailure: ((String, String) -> Void)?
    var onRemoved: ((String) -> Void)?
    var onIdentityInvalidated: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    private var manager: IOHIDManager?
    private var devices: [UInt64: TouchDevice] = [:]
    private var handles: [UInt64: IOHIDDevice] = [:]
    private var decoders: [UInt64: HIDReportDecoder] = [:]
    private var frameTimers: [UInt64: Timer] = [:]
    private var rejected: Set<UInt64> = []
    private var ambiguousIdentities: Set<String> = []
    private var lastPublish = Date.distantPast

    func start() {
        guard manager == nil else { return }
        let value = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = value
        IOHIDManagerSetDeviceMatching(value, [
            kIOHIDDeviceUsagePageKey: 0x0D,
            kIOHIDDeviceUsageKey: 0x04
        ] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(value, { context, result, _, device in
            guard let context else { return }
            Unmanaged<HIDService>.fromOpaque(context).takeUnretainedValue().attach(device, result: result)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(value, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDService>.fromOpaque(context).takeUnretainedValue().detach(device)
        }, context)
        IOHIDManagerRegisterInputReportCallback(value, { context, result, sender, _, reportID, bytes, length in
            guard let context, let sender, length >= 0, length <= 65536 else { return }
            let service = Unmanaged<HIDService>.fromOpaque(context).takeUnretainedValue()
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            service.receive(device, result: result, reportID: reportID, data: Data(bytes: bytes, count: length))
        }, context)
        IOHIDManagerScheduleWithRunLoop(value, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(value, IOOptionBits(kIOHIDOptionsTypeNone))
        if result != kIOReturnSuccess {
            onStatus?("Touch access unavailable (\(String(format: "0x%08X", result))). Allow Input Monitoring, then rescan.")
        } else {
            onStatus?("Listening for USB touchscreen connections")
        }
    }

    func stop() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
        IOHIDManagerRegisterInputReportCallback(manager, nil, nil)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        frameTimers.values.forEach { $0.invalidate() }; frameTimers.removeAll()
        for device in devices.values { onRemoved?(device.id) }
        devices.removeAll(); handles.removeAll(); decoders.removeAll(); rejected.removeAll()
        publish()
    }

    func rescan() { stop(); start() }

    /// The standard Device Mode feature is also used by TouchMyMac's input layer.
    /// Only invoked by the user's selected-device action; never writes vendor reports.
    func requestMultitouchMode(for selectedID: String) -> String {
        guard let pair = devices.first(where: { $0.value.id == selectedID }),
              let device = handles[pair.key] else { return "Connect and select a touch controller first." }
        let matching = [kIOHIDElementUsagePageKey: 0x0D, kIOHIDElementUsageKey: 0x52] as CFDictionary
        let elements = IOHIDDeviceCopyMatchingElements(device, matching, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement] ?? []
        let candidates = elements.filter {
            IOHIDElementGetType($0) == kIOHIDElementTypeFeature &&
            IOHIDElementGetLogicalMin($0) <= 2 && IOHIDElementGetLogicalMax($0) >= 2 &&
            IOHIDElementGetReportCount($0) == 1
        }
        guard candidates.count == 1, let element = candidates.first else {
            return "This controller does not advertise a single standard multitouch-mode setting. No change was made."
        }
        let value = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, mach_absolute_time(), 2)
        let result = IOHIDDeviceSetValue(device, element, value)
        guard result == kIOReturnSuccess else {
            return "The controller did not accept touch mode (\(String(format: "0x%08X", result))). No vendor-specific commands were sent."
        }
        return "Standard multitouch mode requested. Rescan devices, then check Live Touch. Reconnect the USB cable if you need to restore the controller’s default mode."
    }

    private func registryID(_ device: IOHIDDevice) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &id)
        return id
    }

    private func attach(_ device: IOHIDDevice, result: IOReturn) {
        let id = registryID(device)
        guard devices[id] == nil else { return }
        handles[id] = device
        func number(_ key: String) -> Int { (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0 }
        func string(_ key: String) -> String { IOHIDDeviceGetProperty(device, key as CFString) as? String ?? "" }
        let vendor = number(kIOHIDVendorIDKey), product = number(kIOHIDProductIDKey)
        let location = number(kIOHIDLocationIDKey)
        // A composite monitor may expose multiple HID interfaces at one USB location.
        // Use its interface number too; an unknown interface gets a session-only ID,
        // which intentionally requires reselection after reconnect instead of merging streams.
        let interface = IORegistryEntrySearchCFProperty(
            IOHIDDeviceGetService(device), kIOServicePlane, "bInterfaceNumber" as CFString,
            kCFAllocatorDefault, IOOptionBits(kIORegistryIterateParents | kIORegistryIterateRecursively)
        ) as? NSNumber
        var stableID = "\(vendor):\(product):\(location):"
        if location != 0, let interface { stableID += "interface-\(interface.intValue)" }
        else { stableID += "session-\(id)" }
        if let collision = devices.first(where: { $0.value.id == stableID }) {
            let ambiguousID = stableID
            ambiguousIdentities.insert(ambiguousID)
            devices[collision.key]?.id = "\(ambiguousID):session-\(collision.key)"
            onRemoved?(ambiguousID)
            onIdentityInvalidated?(ambiguousID)
        }
        if ambiguousIdentities.contains(stableID) { stableID += ":session-\(id)" }
        let data = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data ?? Data()
        var entry = TouchDevice(id: stableID, name: string(kIOHIDProductKey).isEmpty ? "USB touchscreen" : string(kIOHIDProductKey),
                                vendorID: vendor, productID: product, transport: string(kIOHIDTransportKey),
                                descriptor: data, support: "Checking touch format", usable: false)
        do {
            guard result == kIOReturnSuccess else { throw NSError(domain: "HID", code: Int(result)) }
            let decoder = try HIDDescriptor(data: data)
            decoders[id] = HIDReportDecoder(descriptor: decoder)
            entry.support = decoder.summary
            entry.usable = true
        } catch {
            entry.support = "Touch format needs a device profile"
            entry.error = error.localizedDescription
        }
        devices[id] = entry
        publish()
    }

    private func detach(_ device: IOHIDDevice) {
        let id = registryID(device)
        if let entry = devices.removeValue(forKey: id) { onRemoved?(entry.id) }
        decoders.removeValue(forKey: id); rejected.remove(id)
        handles.removeValue(forKey: id)
        frameTimers.removeValue(forKey: id)?.invalidate()
        publish()
    }

    private func receive(_ device: IOHIDDevice, result: IOReturn, reportID: UInt32, data: Data) {
        let id = registryID(device)
        guard let entry = devices[id], decoders[id] != nil, !rejected.contains(id) else { return }
        do {
            guard result == kIOReturnSuccess else { throw NSError(domain: "HID input", code: Int(result)) }
            // IOKit input reports preserve the on-wire ID prefix. Do not guess/insert bytes.
            guard reportID == 0 || data.first == UInt8(exactly: reportID) else {
                throw NSError(domain: "HID input", code: 1, userInfo: [NSLocalizedDescriptionKey: "Report ID does not match its payload."])
            }
            let frame = try decoders[id]?.decode(report: data, timestamp: ProcessInfo.processInfo.systemUptime)
            updateFrameDeadline(id: id)
            guard let frame else { return }
            devices[id]?.reports += 1
            onFrame?(entry.id, frame)
            if Date().timeIntervalSince(lastPublish) > 0.25 { publish() }
        } catch {
            reject(id: id, message: error.localizedDescription)
        }
    }

    private func updateFrameDeadline(id: UInt64) {
        guard decoders[id]?.isAssemblingFrame == true else {
            frameTimers.removeValue(forKey: id)?.invalidate()
            return
        }
        guard frameTimers[id] == nil else { return }
        let timer = Timer(timeInterval: 0.050, repeats: false) { [weak self] _ in
            guard let self, self.decoders[id]?.isAssemblingFrame == true else { return }
            self.reject(id: id, message: "A split touch frame did not finish within 50 ms. Rescan to retry.")
        }
        frameTimers[id] = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func reject(id: UInt64, message: String) {
        // Latch failures so a continuation can never become an independent frame.
        frameTimers.removeValue(forKey: id)?.invalidate()
        decoders[id]?.reset()
        rejected.insert(id)
        devices[id]?.error = message
        devices[id]?.usable = false
        devices[id]?.support = "Input paused: unsupported or incomplete report"
        if let entry = devices[id] { onFailure?(entry.id, message) }
        publish()
    }

    private func publish() {
        lastPublish = Date()
        onDevices?(devices.values.sorted { $0.name < $1.name })
    }
}
