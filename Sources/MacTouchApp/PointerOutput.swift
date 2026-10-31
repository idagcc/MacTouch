import AppKit
import ApplicationServices
import MacTouchCore

final class PointerOutput {
    private let source = CGEventSource(stateID: .privateState)
    private var lastDown = -Double.infinity
    private var lastPoint = CGPoint.zero
    private var clickCount: Int64 = 1
    private var scrollRemainder = CGPoint.zero
    private var zoomRemainder = 0.0

    func send(_ actions: [PointerAction]) {
        for action in actions {
            if case .scroll = action {} else { scrollRemainder = .zero }
            if case .mapZoom = action {} else { zoomRemainder = 0 }
            switch action {
            case let .move(x, y): mouse(.mouseMoved, x, y)
            case let .down(x, y):
                let now = ProcessInfo.processInfo.systemUptime
                let nearby = hypot(x - lastPoint.x, y - lastPoint.y) < 6
                clickCount = now - lastDown < NSEvent.doubleClickInterval && nearby ? min(clickCount + 1, 3) : 1
                lastDown = now; lastPoint = CGPoint(x: x, y: y)
                mouse(.leftMouseDown, x, y)
            case let .drag(x, y): mouse(.leftMouseDragged, x, y)
            case let .up(x, y): mouse(.leftMouseUp, x, y)
            case let .scroll(dx, dy):
                guard dx.isFinite, dy.isFinite else { continue }
                scrollRemainder.x += max(-10000, min(10000, dx))
                scrollRemainder.y += max(-10000, min(10000, dy))
                let horizontal = scrollRemainder.x.rounded(.towardZero)
                let vertical = scrollRemainder.y.rounded(.towardZero)
                scrollRemainder.x -= horizontal; scrollRemainder.y -= vertical
                guard horizontal != 0 || vertical != 0 else { continue }
                let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                    wheel1: Int32(vertical), wheel2: Int32(horizontal), wheel3: 0)
                event?.post(tap: .cghidEventTap)
            case let .mapZoom(x, y, delta):
                guard x.isFinite, y.isFinite, delta.isFinite else { continue }
                zoomRemainder += min(120, max(-120, delta))
                let vertical = zoomRemainder.rounded(.towardZero)
                zoomRemainder -= vertical
                guard vertical != 0 else { continue }
                // The location must be over the embedded map, not Safari's
                // toolbar. Flags apply only to this wheel event; no modifier
                // key is pressed or left held after cancellation.
                mouse(.mouseMoved, x, y)
                let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                                    wheel1: Int32(vertical), wheel2: 0, wheel3: 0)
                event?.location = CGPoint(x: x, y: y)
                event?.flags = .maskCommand
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    func resetScroll() { scrollRemainder = .zero; zoomRemainder = 0 }

    private func mouse(_ type: CGEventType, _ x: Double, _ y: Double) {
        guard x.isFinite, y.isFinite else { return }
        let event = CGEvent(mouseEventSource: source, mouseType: type,
                            mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)
        event?.setIntegerValueField(.mouseEventClickState, value: clickCount)
        event?.post(tap: .cghidEventTap)
    }
}
