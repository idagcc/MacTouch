import AppKit
import SwiftUI
import MacTouchCore

private let testerMint = Color(red: 0.43, green: 0.88, blue: 0.71)

struct TouchTesterView: View {
    private enum Source: String, CaseIterable {
        case sensor = "Sensor", simulation = "Simulation"
    }

    @ObservedObject var model: AppModel
    @State private var source: Source = CommandLine.arguments.contains("--simulate") ? .simulation : .sensor
    // Demo points never enter AppModel, HID decoding, diagnostics or pointer output.
    @State private var simulatedContacts = preset(count: 3)
    @State private var simulationPeak = 3

    private var isSimulation: Bool { source == .simulation }
    private var points: [TouchContact] { isSimulation ? simulatedContacts : model.contacts }
    private var peak: Int { isSimulation ? simulationPeak : model.touchTest.peakContacts }
    private var tint: Color { isSimulation ? .orange : testerMint }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 16) {
                Picker("Touch source", selection: $source) {
                    ForEach(Source.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).frame(width: 240)
                Spacer()
                Button {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                } label: {
                    Label("Full screen", systemImage: "arrow.up.left.and.arrow.down.right")
                }.help("Expand the tester; press Control–Command–F to leave full screen")
            }

            if !isSimulation { controllerPicker }

            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 28) {
                    stat("POINTS NOW", value: "\(points.count)")
                    stat("MOST TOGETHER", value: "\(peak)")
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 9) {
                        Label(isSimulation ? "SIMULATED" : "SENSOR INPUT", systemImage: isSimulation ? "cursorarrow.rays" : "cable.connector")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(tint)
                        Text(isSimulation ? "Mouse-generated points" : "\(model.touchTest.frames) sensor frames")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Button("Reset peak") {
                            if isSimulation { simulationPeak = simulatedContacts.count }
                            else { model.resetTouchTest() }
                        }.controlSize(.small)
                    }.padding(.top, 5)
                }

                TouchTestSurface(contacts: points, simulation: isSimulation,
                                 move: isSimulation ? moveSimulatedContact : nil)
                    .frame(height: 310)

                if isSimulation {
                    HStack(spacing: 8) {
                        ForEach([1, 2, 3, 5, 10], id: \.self) { count in
                            Button("\(count) \(count == 1 ? "finger" : "fingers")") { simulate(count) }
                                .accessibilityLabel("Simulate \(count) fingers")
                        }
                        Spacer(minLength: 0)
                        Button("Lift all") { simulatedContacts = [] }
                    }
                    Text("Choose a finger count, then drag the numbered points with your mouse. Simulated points do not measure your sensor.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 18) {
                        milestone(2)
                        milestone(3)
                        Spacer()
                        Text("Pointer control paused").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Text("Touch the sensor with one, two, then three fingers. Lift them individually and watch the count return to zero. The whole sensor surface appears above; no video cable is needed.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(22).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))

            if !isSimulation { sensorStatus }
        }
    }

    private var controllerPicker: some View {
        HStack(spacing: 12) {
            Image(systemName: "cable.connector").foregroundStyle(testerMint)
            Picker("Sensor controller", selection: $model.selectedDeviceID) {
                Text("Choose a controller").tag("")
                if !model.selectedDeviceID.isEmpty && model.selectedDevice == nil {
                    Text("Saved controller · disconnected").tag(model.selectedDeviceID)
                }
                ForEach(model.devices) { Text("\($0.name) · \($0.usbID)").tag($0.id) }
            }.labelsHidden().accessibilityLabel("Sensor controller")
            Button("Rescan", action: model.rescan)
        }
    }

    private var sensorStatus: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: statusSymbol).foregroundStyle(model.inputAllowed ? testerMint : .orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(statusTitle).font(.system(size: 13, weight: .semibold))
                Text(statusDetail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !model.inputAllowed {
                    Button("Open Input Monitoring", action: model.requestInputMonitoring).padding(.top, 4)
                } else if model.selectedDevice != nil && model.touchTest.peakContacts < 2 {
                    Button("Request multitouch mode", action: model.requestMultitouchMode).padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(testerMint.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusSymbol: String {
        !model.inputAllowed ? "lock.circle" : (model.selectedDevice?.usable == true ? "waveform.path" : "info.circle")
    }

    private var statusTitle: String {
        if !model.inputAllowed { return "Allow MacTouch to read the sensor" }
        guard let device = model.selectedDevice else { return "Choose your touch sensor" }
        if !device.usable { return "Sensor input is unavailable" }
        return model.touchTest.frames == 0 ? "Ready for your first touch" : model.lastTouch
    }

    private var statusDetail: String {
        if !model.inputAllowed {
            return "Enable MacTouch in Privacy & Security → Input Monitoring, then reopen MacTouch and rescan. Accessibility is only needed for cursor control. You can use Simulation immediately."
        }
        guard let device = model.selectedDevice else { return "Connect the sensor’s USB cable and select its controller above." }
        if !device.usable { return device.error ?? device.support }
        return "\(device.support). The peak count records contacts actually received together; advertised capacity alone does not verify multitouch."
    }

    private func stat(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.system(size: 48, weight: .light, design: .rounded)).monospacedDigit().foregroundStyle(tint)
            Text(title).font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1).foregroundStyle(.secondary)
        }.accessibilityElement(children: .ignore).accessibilityLabel("\(title), \(value)")
    }

    private func milestone(_ count: Int) -> some View {
        Label("\(count)+ together: \(peak >= count ? "seen" : "waiting")", systemImage: peak >= count ? "checkmark.circle.fill" : "circle.dashed")
            .font(.system(size: 11, weight: .medium)).foregroundStyle(peak >= count ? testerMint : .secondary)
    }

    private func simulate(_ count: Int) {
        simulatedContacts = Self.preset(count: count)
        simulationPeak = max(simulationPeak, count)
    }

    private func moveSimulatedContact(_ id: Int, to location: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0,
              let index = simulatedContacts.firstIndex(where: { $0.id == id }) else { return }
        simulatedContacts[index] = TouchContact(id: id,
            x: min(1, max(0, location.x / size.width)),
            y: min(1, max(0, location.y / size.height)))
    }

    private static func preset(count: Int) -> [TouchContact] {
        let columns = count <= 3 ? count : (count <= 6 ? 3 : 5)
        let rows = (count + columns - 1) / columns
        return (0..<count).map { index in
            let row = index / columns
            let rowCount = min(columns, count - row * columns)
            return TouchContact(id: index + 1,
                x: 0.1 + 0.8 * (Double(index % columns) + 0.5) / Double(rowCount),
                y: 0.1 + 0.8 * (Double(row) + 0.5) / Double(rows))
        }
    }
}

private struct TouchTestSurface: View {
    let contacts: [TouchContact]
    let simulation: Bool
    let move: ((Int, CGPoint, CGSize) -> Void)?
    private let colors: [Color] = [testerMint, .blue, .orange, .purple, .pink, .yellow, .teal, .red, .indigo, .cyan]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Canvas { context, size in
                    var grid = Path()
                    for x in stride(from: 0.0, through: size.width, by: 30) {
                        for y in stride(from: 0.0, through: size.height, by: 30) {
                            grid.addEllipse(in: CGRect(x: x, y: y, width: 2, height: 2))
                        }
                    }
                    context.fill(grid, with: .color(.white.opacity(0.10)))
                    var crosshair = Path()
                    crosshair.move(to: CGPoint(x: size.width / 2, y: 0))
                    crosshair.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                    crosshair.move(to: CGPoint(x: 0, y: size.height / 2))
                    crosshair.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                    context.stroke(crosshair, with: .color(.white.opacity(0.05)), lineWidth: 1)
                }
                if contacts.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: simulation ? "cursorarrow.rays" : "hand.draw").font(.system(size: 34, weight: .ultraLight))
                        Text(simulation ? "Choose a finger count below" : "Place your fingers on the sensor").font(.system(size: 13))
                    }.foregroundStyle(.secondary)
                }
                ForEach(contacts, id: \.id) { contact in
                    let color = colors[Int(contact.id.magnitude % UInt(colors.count))]
                    Circle().fill(color.opacity(0.18)).frame(width: 52, height: 52)
                        .overlay(Circle().stroke(color, lineWidth: 2))
                        .overlay(Text("\(contact.id)").font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundStyle(color))
                        .overlay(alignment: .bottom) {
                            Text(String(format: "%.0f%%, %.0f%%", contact.x * 100, contact.y * 100))
                                .font(.system(size: 9, design: .monospaced)).foregroundStyle(color).offset(y: 20)
                        }
                        .contentShape(Circle())
                        .position(x: min(geometry.size.width - 36, max(36, contact.x * geometry.size.width)),
                                  y: min(geometry.size.height - 48, max(36, contact.y * geometry.size.height)))
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("touchTestSurface"))
                            .onChanged { move?(contact.id, $0.location, geometry.size) })
                        .allowsHitTesting(move != nil)
                        .accessibilityLabel("\(simulation ? "Simulated" : "Sensor") contact \(contact.id), X \(Int(contact.x * 100)) percent, Y \(Int(contact.y * 100)) percent")
                }
                VStack {
                    HStack {
                        Text(simulation ? "SIMULATION" : "SENSOR SURFACE").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1)
                        Spacer()
                    }
                    Spacer()
                }.padding(14).foregroundStyle(.tertiary).allowsHitTesting(false)
            }.coordinateSpace(name: "touchTestSurface")
        }.background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.07)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(simulation ? "Simulated" : "Sensor") touch surface, \(contacts.count) points")
    }
}
