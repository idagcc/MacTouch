import SwiftUI
import MacTouchCore

private let accent = Color(red: 0.43, green: 0.88, blue: 0.71)
private let panel = Color.white.opacity(0.045)

private enum Section: String, CaseIterable {
    case connection = "Connection", tester = "Touch tester", settings = "Touch settings", diagnostics = "Diagnostics"
    var symbol: String {
        switch self { case .connection: return "display"; case .tester: return "hand.draw"; case .settings: return "slider.horizontal.3"; case .diagnostics: return "waveform.path.ecg" }
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @State private var section: Section = CommandLine.arguments.contains("--tester") ? .tester : .connection

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Color.white.opacity(0.05))
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if let notice = model.notice {
                        HStack(alignment: .top) {
                            Image(systemName: "info.circle").foregroundStyle(accent)
                            Text(notice).font(.system(size: 12)).textSelection(.enabled)
                            Spacer()
                            Button { model.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                        }.padding(14).background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    }
                    switch section {
                    case .connection: connection
                    case .tester: TouchTesterView(model: model)
                    case .settings: touchSettings
                    case .diagnostics: diagnostics
                    }
                }.padding(30)
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .background(Color(red: 0.075, green: 0.087, blue: 0.096))
        .preferredColorScheme(.dark)
        .tint(accent)
        .onAppear { model.touchTesterActive = section == .tester }
        .onChange(of: section) { model.touchTesterActive = $0 == .tester }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "hand.point.up.left.fill").font(.system(size: 23)).foregroundStyle(accent)
                Text("MacTouch").font(.system(size: 22, weight: .semibold, design: .rounded))
            }.padding(.top, 26).padding(.bottom, 4)
            Text("A connection you can feel.").font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 30)
            ForEach(Section.allCases, id: \.self) { item in
                Button { section = item } label: {
                    Label(item.rawValue, systemImage: item.symbol)
                        .font(.system(size: 13, weight: section == item ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        .background(section == item ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        .foregroundStyle(section == item ? accent : Color.secondary)
                }.buttonStyle(.plain)
            }
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Label("Lives in your menu bar", systemImage: "menubar.rectangle").font(.system(size: 11, weight: .medium))
                Text("Close this window and touch stays connected.").font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
            }.padding(14).background(panel, in: RoundedRectangle(cornerRadius: 12))
            Text("DEVELOPMENT PREVIEW · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.2")").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.tertiary).padding(.top, 10)
        }.padding(18).frame(width: 194).background(Color.black.opacity(0.15))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(section.rawValue.uppercased()).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(2).foregroundStyle(accent)
                Text(title).font(.system(size: 29, weight: .semibold, design: .rounded))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(model.isRunning ? accent : .orange).frame(width: 6, height: 6)
                Text(section == .tester ? "POINTER PAUSED" : (model.isRunning ? "CONNECTED" : "SETUP")).font(.system(size: 9, weight: .semibold)).tracking(1)
            }.padding(.horizontal, 11).padding(.vertical, 8).background(panel, in: Capsule())
        }
    }

    private var title: String {
        switch section { case .connection: return "Bring your screen to life."; case .tester: return "See every finger."; case .settings: return "Make touch feel right."; case .diagnostics: return "See what’s connected." }
    }
    private var subtitle: String {
        switch section { case .connection: return "Connect your USB touchscreen, then choose where it points."; case .tester: return "Count real sensor contacts, or try the simulator with your mouse."; case .settings: return "Tune the selected controller and keep MacTouch ready at login."; case .diagnostics: return "Check the input path and export a report for device support." }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 20) {
                    cardHeading("01", "Touch controller", symbol: "cable.connector")
                    Picker("Controller", selection: $model.selectedDeviceID) {
                        Text("Choose a controller").tag("")
                        if !model.selectedDeviceID.isEmpty && model.selectedDevice == nil {
                            Text("Saved controller · disconnected").tag(model.selectedDeviceID)
                        }
                        ForEach(model.devices) { device in Text("\(device.name) · \(device.usbID)").tag(device.id) }
                    }.labelsHidden().accessibilityLabel("Touch controller")
                    Text(model.selectedDevice?.support ?? "Connect the monitor’s USB touch cable to your Mac. A video cable alone won’t carry touch.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
                    Divider()
                    cardHeading("02", "Target display", symbol: "display")
                    Picker("Display", selection: $model.selectedDisplayID) {
                        Text("Choose a display").tag("")
                        if !model.selectedDisplayID.isEmpty && model.selectedDisplay == nil {
                            Text("Saved display · disconnected").tag(model.selectedDisplayID)
                        }
                        ForEach(model.displays) { display in Text(display.name).tag(display.id) }
                    }.labelsHidden().accessibilityLabel("Target touchscreen display")
                    Text("Choose the physical screen you’re touching. This mapping is remembered for this USB port.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(panel, in: RoundedRectangle(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("LIVE TOUCH").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1)
                        Spacer()
                        Text("\(model.contacts.count) points · peak \(model.selectedDevice?.peakContacts ?? 0)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    TouchCanvas(contacts: model.contacts).frame(height: 194)
                    Text(model.lastTouch).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("Preview works while pointer control is paused.").font(.system(size: 10)).foregroundStyle(.tertiary)
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(panel, in: RoundedRectangle(cornerRadius: 16))
            }
            VStack(spacing: 16) {
                permissionRow("Pointer control", detail: "Allows touches to click and drag in your apps.", allowed: model.accessibilityAllowed, action: model.requestAccessibility)
                Divider()
                permissionRow("Read touch input", detail: "If no touches arrive, allow Input Monitoring, reopen MacTouch and rescan.", allowed: model.inputAllowed, action: model.requestInputMonitoring)
            }.padding(20).background(panel, in: RoundedRectangle(cornerRadius: 16))
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.headline).font(.system(size: 14, weight: .semibold))
                    Text("Tap to click · move to drag · two fingers to scroll").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Enable touch", isOn: $model.enabled).toggleStyle(.switch).fixedSize()
            }.padding(20).background(accent.opacity(0.075), in: RoundedRectangle(cornerRadius: 16))
            HStack {
                Text("ASUS + Mac mini: USB for touch, HDMI for video.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Rescan devices", action: model.rescan).buttonStyle(.bordered)
            }
        }
    }

    private var touchSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 20) {
                Label(model.selectedDevice?.name ?? "Choose a controller in Connection", systemImage: "hand.point.up.left").font(.headline)
                Picker("Touch rotation", selection: $model.configuration.rotation) {
                    Text("0°").tag(0); Text("90°").tag(90); Text("180°").tag(180); Text("270°").tag(270)
                }.pickerStyle(.segmented)
                Text("Use rotation only if the touch position does not follow the display orientation.").font(.system(size: 11)).foregroundStyle(.secondary)
                Toggle("Flip horizontally", isOn: $model.configuration.invertX)
                Toggle("Flip vertically", isOn: $model.configuration.invertY)
                Divider()
                Toggle("Two-finger scrolling", isOn: $model.configuration.twoFingerScroll)
                HStack {
                    Text("Scroll speed").frame(width: 100, alignment: .leading)
                    Slider(value: $model.configuration.scrollSpeed, in: 0.2...3, step: 0.1)
                    Text(String(format: "%.1f×", model.configuration.scrollSpeed)).monospacedDigit().frame(width: 40)
                }
                Text("Adding a second finger ends a drag. Lift both fingers before starting another click.").font(.system(size: 11)).foregroundStyle(.secondary)
            }.disabled(model.selectedDevice == nil).padding(24).background(panel, in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Launch MacTouch at login", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin)).toggleStyle(.switch)
                Text(model.loginStatus).font(.system(size: 12)).foregroundStyle(.secondary)
                Text("Starts in the menu bar after you sign in. Keep the app in Applications so its permissions and startup entry stay consistent.").font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
                Button("Open Login Items", action: model.openLoginSettings)
            }.padding(24).background(panel, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 16) {
                Label(model.serviceStatus, systemImage: "antenna.radiowaves.left.and.right").font(.system(size: 13, weight: .medium))
                HStack(spacing: 40) {
                    metric("CONTROLLERS", value: "\(model.devices.count)")
                    metric("DISPLAYS", value: "\(model.displays.count)")
                    metric("TOUCH FRAMES", value: "\(model.frameCount)")
                }
                Divider()
                if model.devices.isEmpty {
                    Text("No standard HID touchscreen found. Check the USB data cable, adapter and monitor power, then rescan. The display’s video connection is separate.").font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(4)
                }
                ForEach(model.devices) { device in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(device.name).font(.headline)
                        Text("\(device.transport) · \(device.usbID) · \(device.reports) frames").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        Text(device.support).font(.system(size: 12))
                        Text("Contacts now: \(device.currentContacts) · Most seen together: \(device.peakContacts)").font(.system(size: 11)).foregroundStyle(.secondary)
                        if device.modeStatus != "Not requested" {
                            Text(device.modeStatus).font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if let error = device.error { Text(error).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) }
                    }
                }
                HStack {
                    Button("Rescan devices", action: model.rescan)
                    Button("Export diagnostics…", action: model.exportDiagnostics).buttonStyle(.borderedProminent).foregroundStyle(.black)
                }
                Divider()
                Text("Only one finger detected?").font(.system(size: 12, weight: .semibold))
                Text("Some controllers start in mouse mode. You can request their advertised standard multitouch mode. Pointer control pauses; reconnect USB to restore the controller’s default if needed.").font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Request multitouch mode", action: model.requestMultitouchMode).disabled(model.selectedDevice == nil)
            }.padding(24).background(panel, in: RoundedRectangle(cornerRadius: 16))
            VStack(alignment: .leading, spacing: 10) {
                Text("Built for standard USB touchscreens").font(.headline)
                Text("This preview supports standard single-touch, serial contact updates, parallel multi-touch and split frames with matching scan times. Vendor-specific controllers and ambiguous touch formats may need an additional profile. ASUS hardware compatibility still needs a test on your monitor.")
                Text("Touch is translated into mouse actions. Native trackpad gestures, pinch-to-zoom, pressure and pre-login control are not included.")
                Text("Diagnostics stay on your Mac unless you choose to share the exported file.")
            }.font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4).padding(24).background(panel, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func cardHeading(_ number: String, _ title: String, symbol: String) -> some View {
        HStack {
            Text(number).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(accent)
            Text(title).font(.system(size: 13, weight: .semibold))
            Spacer(); Image(systemName: symbol).foregroundStyle(.secondary)
        }
    }

    private func permissionRow(_ title: String, detail: String, allowed: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: allowed ? "checkmark.circle.fill" : "lock.circle").font(.system(size: 22)).foregroundStyle(allowed ? accent : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if allowed { Text("Allowed").font(.system(size: 11)).foregroundStyle(accent) }
            else { Button("Allow…", action: action).buttonStyle(.bordered) }
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value).font(.system(size: 30, weight: .light, design: .rounded)).foregroundStyle(accent)
            Text(title).font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
        }
    }
}

private struct TouchCanvas: View {
    let contacts: [TouchContact]
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Canvas { context, size in
                    var path = Path()
                    for x in stride(from: 0.0, through: size.width, by: 22) {
                        for y in stride(from: 0.0, through: size.height, by: 22) {
                            path.addEllipse(in: CGRect(x: x, y: y, width: 1.5, height: 1.5))
                        }
                    }
                    context.fill(path, with: .color(.white.opacity(0.13)))
                }
                if contacts.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "hand.point.up.left").font(.system(size: 32, weight: .ultraLight))
                        Text("Touch your screen").font(.system(size: 11))
                    }.foregroundStyle(.tertiary)
                }
                ForEach(contacts, id: \.id) { contact in
                    Circle().fill(accent.opacity(0.2)).frame(width: 34, height: 34)
                        .overlay(Circle().stroke(accent, lineWidth: 1.5))
                        .overlay(Text("\(contact.id)").font(.system(size: 10, weight: .semibold)).foregroundStyle(accent))
                        .position(x: max(17, min(geometry.size.width - 17, contact.x * geometry.size.width)),
                                  y: max(17, min(geometry.size.height - 17, contact.y * geometry.size.height)))
                }
            }
        }.background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("Live touch preview, \(contacts.count) contacts")
    }
}
