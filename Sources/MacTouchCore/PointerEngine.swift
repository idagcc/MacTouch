import Foundation
import CoreGraphics

/// Coordinates are normalized to the touch surface before these transforms.
/// Inversions apply first, followed by clockwise rotation.
public struct PointerConfiguration: Codable, Equatable, Sendable {
    public var rotation: Int
    public var invertX: Bool
    public var invertY: Bool
    public var twoFingerScroll: Bool
    public var scrollSpeed: Double
    public var mapPinchZoom: Bool

    public init(
        rotation: Int = 0,
        invertX: Bool = false,
        invertY: Bool = false,
        twoFingerScroll: Bool = true,
        scrollSpeed: Double = 1,
        mapPinchZoom: Bool = false
    ) {
        self.rotation = rotation
        self.invertX = invertX
        self.invertY = invertY
        self.twoFingerScroll = twoFingerScroll
        self.scrollSpeed = scrollSpeed
        self.mapPinchZoom = mapPinchZoom
    }

    private enum CodingKeys: String, CodingKey {
        case rotation, invertX, invertY, twoFingerScroll, scrollSpeed, mapPinchZoom
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rotation = try values.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        invertX = try values.decodeIfPresent(Bool.self, forKey: .invertX) ?? false
        invertY = try values.decodeIfPresent(Bool.self, forKey: .invertY) ?? false
        twoFingerScroll = try values.decodeIfPresent(Bool.self, forKey: .twoFingerScroll) ?? true
        scrollSpeed = try values.decodeIfPresent(Double.self, forKey: .scrollSpeed) ?? 1
        mapPinchZoom = try values.decodeIfPresent(Bool.self, forKey: .mapPinchZoom) ?? false
    }

    fileprivate var sanitized: Self {
        let angle = ((rotation % 360) + 360) % 360
        return Self(
            rotation: [0, 90, 180, 270].contains(angle) ? angle : 0,
            invertX: invertX,
            invertY: invertY,
            twoFingerScroll: twoFingerScroll,
            scrollSpeed: scrollSpeed.isFinite ? min(4, max(0.1, scrollSpeed)) : 1,
            mapPinchZoom: mapPinchZoom
        )
    }
}

public enum PointerAction: Equatable, Sendable {
    case move(x: Double, y: Double)
    case down(x: Double, y: Double)
    case drag(x: Double, y: Double)
    case up(x: Double, y: Double)
    /// Positive deltas follow finger movement, for natural scrolling.
    case scroll(dx: Double, dy: Double)
    /// Positive delta zooms in. The host sends Command-modified wheel input
    /// at this location for maps that support that public input convention.
    case mapZoom(x: Double, y: Double, delta: Double)
}

public enum TwoFingerIntent: String, Sendable {
    case deciding, scrolling, pinching
}

public enum CoordinateMapper {
    /// Use Quartz display bounds directly, without a Cocoa Y-axis flip or a
    /// Retina backing-scale multiplication. The final coordinate stays inside
    /// the selected display, including when its origin is negative.
    public static func map(
        x: Double,
        y: Double,
        bounds: CGRect,
        configuration: PointerConfiguration = .init()
    ) -> CGPoint? {
        guard x.isFinite, y.isFinite, valid(bounds) else { return nil }
        let configuration = configuration.sanitized
        var u = min(1, max(0, x))
        var v = min(1, max(0, y))
        if configuration.invertX { u = 1 - u }
        if configuration.invertY { v = 1 - v }
        switch configuration.rotation {
        case 90: (u, v) = (1 - v, u)
        case 180: (u, v) = (1 - u, 1 - v)
        case 270: (u, v) = (v, 1 - u)
        default: break
        }
        return CGPoint(
            x: bounds.minX + u * max(0, bounds.width - 1),
            y: bounds.minY + v * max(0, bounds.height - 1)
        )
    }

    fileprivate static func valid(_ bounds: CGRect) -> Bool {
        !bounds.isInfinite && !bounds.isNull
            && bounds.origin.x.isFinite && bounds.origin.y.isFinite
            && bounds.width.isFinite && bounds.height.isFinite
            && bounds.maxX.isFinite && bounds.maxY.isFinite
            && bounds.size.width > 0 && bounds.size.height > 0
    }
}

/// Consumes complete contact frames. The host must call `cancel()` on device
/// removal, pause, sleep, permission loss, or a failed report stream.
///
/// A second finger releases any mouse button before scrolling. Once a scroll
/// ends, every finger must lift before a new click can start. Contact IDs may
/// never silently transfer ownership of a held mouse button.
public struct PointerEngine {
    private enum State {
        case idle
        case pressed(id: Int, point: CGPoint)
        case scrolling(ids: [Int], centroid: CGPoint)
        case twoFinger(TwoFingerMotion)
        case suppressed
    }

    private struct Mapping: Equatable {
        var bounds: CGRect
        var configuration: PointerConfiguration
    }

    private var state: State = .idle
    private var mapping: Mapping?

    public init() {}

    public var twoFingerIntent: TwoFingerIntent? {
        switch state {
        case .twoFinger(let motion): return motion.intent
        case .scrolling: return .scrolling
        default: return nil
        }
    }

    public mutating func process(
        frame: TouchFrame,
        bounds: CGRect,
        configuration: PointerConfiguration = .init(),
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> [PointerAction] {
        if frame.contacts.isEmpty { return cancel() }
        guard CoordinateMapper.valid(bounds), frame.contacts.count <= 2,
              Set(frame.contacts.map(\.id)).count == frame.contacts.count
        else { return suppressUntilRelease() }

        let configuration = configuration.sanitized
        let nextMapping = Mapping(bounds: bounds, configuration: configuration)
        if let mapping, mapping != nextMapping {
            self.mapping = nextMapping
            return suppressUntilRelease()
        }
        mapping = nextMapping

        var points: [Int: CGPoint] = [:]
        for contact in frame.contacts {
            guard let point = CoordinateMapper.map(
                x: contact.x, y: contact.y, bounds: bounds,
                configuration: configuration
            ) else { return suppressUntilRelease() }
            points[contact.id] = point
        }

        switch state {
        case .suppressed:
            return []
        case .idle:
            if points.count == 1, let (id, point) = points.first {
                state = .pressed(id: id, point: point)
                return [.move(x: point.x, y: point.y), .down(x: point.x, y: point.y)]
            }
            if configuration.mapPinchZoom {
                guard timestamp.isFinite, timestamp >= 0 else { return suppressUntilRelease() }
                let centroid = Self.centroid(points)
                state = .twoFinger(TwoFingerMotion(points: points, timestamp: timestamp))
                return [.move(x: centroid.x, y: centroid.y)]
            }
            guard configuration.twoFingerScroll else { return suppressUntilRelease() }
            let centroid = Self.centroid(points)
            state = .scrolling(ids: points.keys.sorted(), centroid: centroid)
            return [.move(x: centroid.x, y: centroid.y)]

        case .pressed(let id, let previous):
            // If the original contact disappeared, require a clean lift before
            // accepting another contact, even when it occupies the same slot.
            guard let point = points[id] else { return suppressUntilRelease() }
            if points.count == 2 {
                if configuration.mapPinchZoom {
                    guard timestamp.isFinite, timestamp >= 0 else { return suppressUntilRelease() }
                    let centroid = Self.centroid(points)
                    state = .twoFinger(TwoFingerMotion(points: points, timestamp: timestamp))
                    return [.up(x: previous.x, y: previous.y), .move(x: centroid.x, y: centroid.y)]
                }
                guard configuration.twoFingerScroll else { return suppressUntilRelease() }
                let centroid = Self.centroid(points)
                state = .scrolling(ids: points.keys.sorted(), centroid: centroid)
                return [.up(x: previous.x, y: previous.y), .move(x: centroid.x, y: centroid.y)]
            }
            state = .pressed(id: id, point: point)
            return point == previous ? [] : [.drag(x: point.x, y: point.y)]

        case .scrolling(let ids, let previous):
            guard configuration.twoFingerScroll, points.keys.sorted() == ids else {
                return suppressUntilRelease()
            }
            let centroid = Self.centroid(points)
            state = .scrolling(ids: ids, centroid: centroid)
            // Reject implausible report jumps instead of sending enormous
            // scrolls after a controller reset or contact-ID reuse.
            let dx = centroid.x - previous.x
            let dy = centroid.y - previous.y
            guard abs(dx) <= bounds.width * 0.25,
                  abs(dy) <= bounds.height * 0.25 else { return [] }
            guard dx != 0 || dy != 0 else { return [] }
            return [.scroll(dx: dx * configuration.scrollSpeed, dy: dy * configuration.scrollSpeed)]

        case .twoFinger(var motion):
            guard let actions = motion.update(points: points, bounds: bounds, configuration: configuration, timestamp: timestamp) else {
                return suppressUntilRelease()
            }
            state = .twoFinger(motion)
            return actions
        }
    }

    /// Idempotently releases a held mouse button and resets the gesture.
    public mutating func cancel() -> [PointerAction] {
        let actions = releaseAction()
        state = .idle
        mapping = nil
        return actions
    }

    private mutating func suppressUntilRelease() -> [PointerAction] {
        let actions = releaseAction()
        state = .suppressed
        return actions
    }

    private func releaseAction() -> [PointerAction] {
        if case .pressed(_, let point) = state {
            return [.up(x: point.x, y: point.y)]
        }
        return []
    }

    fileprivate static func centroid(_ points: [Int: CGPoint]) -> CGPoint {
        // This path has exactly two contacts. Halving before addition avoids
        // overflow when hostile inputs use very large but finite bounds.
        let values = Array(points.values)
        return CGPoint(x: values[0].x / 2 + values[1].x / 2,
                       y: values[0].y / 2 + values[1].y / 2)
    }
}

/// Classify a two-finger gesture once, then keep that intent until liftoff.
/// A short grace period accommodates serial controllers delivering one moving
/// finger before the other; it also permits a pinch with one anchored finger.
private struct TwoFingerMotion {
    let initial: [Int: CGPoint]
    let startedAt: TimeInterval
    var previous: [Int: CGPoint]
    var lastTimestamp: TimeInterval
    var intent = TwoFingerIntent.deciding

    init(points: [Int: CGPoint], timestamp: TimeInterval) {
        initial = points; previous = points
        startedAt = timestamp; lastTimestamp = timestamp
    }

    mutating func update(points: [Int: CGPoint], bounds: CGRect,
                         configuration: PointerConfiguration, timestamp: TimeInterval) -> [PointerAction]? {
        guard points.count == 2, points.keys.sorted() == initial.keys.sorted(),
              timestamp.isFinite, timestamp >= lastTimestamp else { return nil }
        lastTimestamp = timestamp
        let diagonal = hypot(bounds.width, bounds.height)
        for (id, point) in points {
            guard let last = previous[id],
                  hypot(point.x - last.x, point.y - last.y) <= diagonal * 0.25 else { return nil }
        }
        let center = PointerEngine.centroid(points)
        let firstCenter = PointerEngine.centroid(initial)
        let lastCenter = PointerEngine.centroid(previous)
        let span = Self.span(points)
        let firstSpan = Self.span(initial)
        let lastSpan = Self.span(previous)
        let translation = hypot(center.x - firstCenter.x, center.y - firstCenter.y)
        let separation = abs(span - firstSpan)
        let bothMoved = points.allSatisfy { id, point in
            guard let start = initial[id] else { return false }
            return hypot(point.x - start.x, point.y - start.y) >= 2
        }
        let wasDeciding = intent == .deciding
        if wasDeciding {
            guard bothMoved || timestamp - startedAt >= 0.06 else { return [] }
            if firstSpan >= 12, span >= 12, separation >= 8,
               abs(log(span / firstSpan)) >= 0.055, separation > translation * 1.25 {
                intent = .pinching
            } else if configuration.twoFingerScroll, translation >= 5, translation > separation * 0.8 {
                intent = .scrolling
            } else { return [] }
        }
        previous = points
        switch intent {
        case .deciding: return []
        case .scrolling:
            let origin = wasDeciding ? firstCenter : lastCenter
            let dx = (center.x - origin.x) * configuration.scrollSpeed
            let dy = (center.y - origin.y) * configuration.scrollSpeed
            return dx == 0 && dy == 0 ? [] : [.scroll(dx: dx, dy: dy)]
        case .pinching:
            let originSpan = wasDeciding ? firstSpan : lastSpan
            guard span >= 12, originSpan >= 12 else { return nil }
            let change = log(span / originSpan)
            guard change.isFinite, abs(change) <= log(2) else { return nil }
            // Pixel wheel deltas, independent of ordinary scroll speed.
            let delta = min(120, max(-120, change * 400))
            return abs(delta) < 0.001 ? [] : [.mapZoom(x: center.x, y: center.y, delta: delta)]
        }
    }

    private static func span(_ points: [Int: CGPoint]) -> Double {
        let values = Array(points.values)
        return hypot(values[0].x - values[1].x, values[0].y - values[1].y)
    }
}
