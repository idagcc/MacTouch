import AppKit
import SwiftUI

@main
enum MacTouchApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let model = AppModel()
    private var item: NSStatusItem!
    private var window: NSWindow?
    private var diagnosticMode = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read-only smoke mode exercises discovery without permission prompts or pointer output.
        diagnosticMode = CommandLine.arguments.contains("--diagnose")
        if diagnosticMode {
            model.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
                if let data = try? model.diagnosticsData() { FileHandle.standardOutput.write(data) }
                model.stop(); NSApp.terminate(nil)
            }
            return
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "hand.point.up.left", accessibilityDescription: "MacTouch")
        item.button?.toolTip = "MacTouch — touchscreen connection"
        let menu = NSMenu(); menu.delegate = self; item.menu = menu
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "MacTouch")
        add("Quit MacTouch", action: #selector(quit), key: "q", menu: applicationMenu)
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        NSApp.mainMenu = mainMenu
        model.start()
        if !UserDefaults.standard.bool(forKey: "hasOpened") || CommandLine.arguments.contains("--show") || CommandLine.arguments.contains("--tester") {
            showWindow()
            UserDefaults.standard.set(true, forKey: "hasOpened")
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: model.headline, action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        add("Open MacTouch…", action: #selector(showWindow), key: ",", menu: menu)
        add(model.enabled ? "Pause touch" : "Enable touch", action: #selector(toggleTouch), key: "", menu: menu)
        add("Rescan devices", action: #selector(rescan), key: "", menu: menu)
        menu.addItem(.separator())
        add("Quit MacTouch", action: #selector(quit), key: "q", menu: menu)
    }

    private func add(_ title: String, action: Selector, key: String, menu: NSMenu) {
        let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: key); entry.target = self
    }

    @objc private func showWindow() {
        if window == nil {
            let value = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            value.title = "MacTouch"
            value.delegate = self
            value.titlebarAppearsTransparent = true
            value.isReleasedWhenClosed = false
            value.minSize = NSSize(width: 920, height: 680)
            value.contentView = NSHostingView(rootView: DashboardView(model: model))
            value.center(); window = value
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleTouch() { model.enabled.toggle() }
    @objc private func rescan() { model.rescan() }
    @objc private func quit() { NSApp.terminate(nil) }
    func windowWillClose(_ notification: Notification) {
        // A closed tester must not leave a background kiosk bridge paused.
        // Reopening starts on Connection rather than a hidden tester page.
        model.touchTesterActive = false
        window?.contentView = nil
        window = nil
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationWillTerminate(_ notification: Notification) { model.stop() }
}
