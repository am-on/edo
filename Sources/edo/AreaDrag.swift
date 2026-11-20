import CoreGraphics

/// What a drag on the area picker does: draw a new area, move the area, or pull one of its edges or corners.
/// Rectangles use top-left-origin coordinates, like the display.
enum AreaDrag: Equatable {
    case create(from: CGPoint)
    case move(original: CGRect, from: CGPoint)
    case resize(Handle, original: CGRect)

    struct Handle: Equatable, Hashable {
        var left = false, right = false, top = false, bottom = false

        static let topLeft = Handle(left: true, top: true)
        static let top = Handle(top: true)
        static let topRight = Handle(right: true, top: true)
        static let right = Handle(right: true)
        static let bottomRight = Handle(right: true, bottom: true)
        static let bottom = Handle(bottom: true)
        static let bottomLeft = Handle(left: true, bottom: true)
        static let left = Handle(left: true)
        static let all: [Handle] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]

        /// Where the handle's knob is drawn on the area's outline.
        func point(on rect: CGRect) -> CGPoint {
            CGPoint(x: left ? rect.minX : right ? rect.maxX : rect.midX,
                    y: top ? rect.minY : bottom ? rect.maxY : rect.midY)
        }
    }

    static let grabDistance: CGFloat = 8
    static let minimumSize: CGFloat = 20

    /// The drag a press at `point` starts: knobs and edges resize, the inside moves, anywhere else draws anew.
    static func starting(at point: CGPoint, area: CGRect?) -> AreaDrag {
        guard let area else { return .create(from: point) }
        if let handle = handle(at: point, on: area) { return .resize(handle, original: area) }
        if area.contains(point) { return .move(original: area, from: point) }
        return .create(from: point)
    }

    static func handle(at point: CGPoint, on rect: CGRect) -> Handle? {
        let near = rect.insetBy(dx: -grabDistance, dy: -grabDistance)
        guard near.contains(point) else { return nil }
        let handle = Handle(left: abs(point.x - rect.minX) <= grabDistance,
                            right: abs(point.x - rect.maxX) <= grabDistance,
                            top: abs(point.y - rect.minY) <= grabDistance,
                            bottom: abs(point.y - rect.maxY) <= grabDistance)
        return handle == Handle() ? nil : handle
    }

    /// The area while the pointer is at `point`, kept inside `bounds`; nil while a new area is still too small.
    func area(at point: CGPoint, within bounds: CGRect) -> CGRect? {
        let p = CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
        switch self {
        case let .create(start):
            let rect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
            return rect.width >= Self.minimumSize && rect.height >= Self.minimumSize ? rect : nil

        case let .move(original, start):
            let x = min(max(original.minX + point.x - start.x, bounds.minX), bounds.maxX - original.width)
            let y = min(max(original.minY + point.y - start.y, bounds.minY), bounds.maxY - original.height)
            return CGRect(origin: CGPoint(x: x, y: y), size: original.size)

        case let .resize(handle, original):
            var minX = original.minX, maxX = original.maxX, minY = original.minY, maxY = original.maxY
            if handle.left { minX = min(p.x, maxX - Self.minimumSize) }
            if handle.right { maxX = max(p.x, minX + Self.minimumSize) }
            if handle.top { minY = min(p.y, maxY - Self.minimumSize) }
            if handle.bottom { maxY = max(p.y, minY + Self.minimumSize) }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }
}
