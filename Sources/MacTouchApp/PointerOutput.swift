import AppKit
import ApplicationServices
import MacTouchCore

final class PointerOutput {
    private let source = CGEventSource(stateID: .privateState)
    private var lastDown = -Double.infinity
    private var lastPoint = CGPoint.zero
    private var clickCount: Int64 = 1
    private var scrollRemainder = CGPoint.zero

    func send(_ actions: [PointerAction]) {
        for action in actions {
            if case .scroll = action {} else { scrollRemainder = .zero }
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
            }
        }
    }

    func resetScroll() { scrollRemainder = .zero }

    private func mouse(_ type: CGEventType, _ x: Double, _ y: Double) {
        guard x.isFinite, y.isFinite else { return }
        let event = CGEvent(mouseEventSource: source, mouseType: type,
                            mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)
        event?.setIntegerValueField(.mouseEventClickState, value: clickCount)
        event?.post(tap: .cghidEventTap)
    }
}
