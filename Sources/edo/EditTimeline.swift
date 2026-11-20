import AppKit
import SwiftUI

/// Waveform with coloured segments; click to seek, double-click to split, drag a boundary to move it.
struct EditTimeline: View {
    @Environment(EditorStore.self) private var store
    @State private var drag: DragMode?
    /// The layout at the start of a drag, so moving a boundary doesn't shift the ground under the pointer.
    @State private var dragLayout: TimelineLayout?

    private enum DragMode {
        case seek
        case boundary(Int)
    }

    private static let rulerHeight: CGFloat = 16
    private static let grabDistance: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            let plan = store.plan
            let levels = store.levels
            let duration = max(store.duration, 0.001)
            let selected = store.selected
            let playhead = store.playhead
            let layout = TimelineLayout(plan: plan, duration: duration, width: geometry.size.width)

            Canvas { context, size in
                Self.draw(in: &context, size: size, layout: layout, plan: plan, levels: levels,
                          duration: duration, selected: selected, playhead: playhead)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if drag == nil {
                            dragLayout = layout
                            if let i = boundary(near: value.startLocation.x, layout: layout, plan: plan) {
                                drag = .boundary(i)
                                store.beginBoundaryDrag()
                            } else {
                                drag = .seek
                            }
                        }
                        let time = (dragLayout ?? layout).time(value.location.x)
                        switch drag {
                        case let .boundary(i): store.moveBoundary(after: i, to: time)
                        default: store.scrub(to: time)
                        }
                    }
                    .onEnded { value in
                        switch drag {
                        case .boundary: store.endBoundaryDrag()
                        // The first click already moved the playhead here, so a double click splits at it.
                        case .seek where (NSApp.currentEvent?.clickCount ?? 0) >= 2 && abs(value.translation.width) < 3:
                            store.splitAtPlayhead()
                        default: break
                        }
                        drag = nil
                        dragLayout = nil
                    }
            )
            .onContinuousHover { phase in
                if case let .active(point) = phase, boundary(near: point.x, layout: layout, plan: plan) != nil {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
        }
        .frame(height: 124)
    }

    private func boundary(near x: CGFloat, layout: TimelineLayout, plan: Plan) -> Int? {
        let distances = plan.segments.indices.dropLast().map { (index: $0, distance: abs(layout.x(plan.segments[$0].end) - x)) }
        guard let nearest = distances.min(by: { $0.distance < $1.distance }), nearest.distance <= Self.grabDistance else { return nil }
        return nearest.index
    }

    static func tint(for segment: Segment) -> Color {
        if segment.isCut { return .gray }
        if segment.speed == 1 { return .blue }
        if segment.speed < 1 { return .purple }
        return .orange
    }

    /// Loudness mapped to half-heights, widened and smoothed so speech reads as one shape.
    private static func envelope(_ levels: [Float], halfHeight: CGFloat) -> [CGFloat] {
        let mapped = levels.map { CGFloat(min(max((Double($0) + 50) / 40, 0), 1)) * halfHeight }
        return mapped.indices.map { i in
            let window = mapped[max(i - 2, 0)...min(i + 2, mapped.count - 1)]
            let peak = window.max() ?? 0
            let mean = window.reduce(0, +) / CGFloat(window.count)
            return (peak + mean) / 2
        }
    }

    private static func draw(in context: inout GraphicsContext, size: CGSize, layout: TimelineLayout, plan: Plan,
                             levels: [Float], duration: Double, selected: Int, playhead: Double) {
        func x(_ time: Double) -> CGFloat { layout.x(time) }
        let lane = CGRect(x: 0, y: 0, width: size.width, height: size.height - rulerHeight)

        let heights = envelope(levels, halfHeight: lane.height * 0.36)
        var wave = Path()
        if !heights.isEmpty {
            let points = heights.indices.map { x((Double($0) + 0.5) * AudioLevels.window) }
            wave.move(to: CGPoint(x: 0, y: lane.midY))
            for (i, h) in heights.enumerated() { wave.addLine(to: CGPoint(x: points[i], y: lane.midY - max(h, 0.5))) }
            for (i, h) in heights.enumerated().reversed() { wave.addLine(to: CGPoint(x: points[i], y: lane.midY + max(h, 0.5))) }
            wave.closeSubpath()
        }

        for (i, segment) in plan.segments.enumerated() {
            let rect = CGRect(x: x(segment.start), y: lane.minY, width: x(segment.end) - x(segment.start), height: lane.height)
                .insetBy(dx: 1, dy: 0)
            guard rect.width > 0 else { continue }
            let shape = Path(roundedRect: rect, cornerRadius: min(6, rect.width / 2))
            let tint = tint(for: segment)
            let isSelected = i == selected

            context.fill(shape, with: .color(tint.opacity(segment.isCut ? 0.06 : (isSelected ? 0.26 : 0.14))))
            context.drawLayer { layer in
                layer.clip(to: shape)
                if segment.isCut {
                    var stripes = Path()
                    var stripe = rect.minX - rect.height
                    while stripe < rect.maxX {
                        stripes.move(to: CGPoint(x: stripe, y: rect.maxY))
                        stripes.addLine(to: CGPoint(x: stripe + rect.height, y: rect.minY))
                        stripe += 8
                    }
                    layer.stroke(stripes, with: .color(.gray.opacity(0.22)), lineWidth: 1)
                }
                layer.fill(wave, with: .color(tint.opacity(segment.isCut ? 0.3 : 0.75)))
            }
            if isSelected {
                context.stroke(shape, with: .color(.accentColor), lineWidth: 2)
            }

            let label = context.resolve(
                Text(segment.isCut ? "Cut" : "\(Plan.format(segment.speed))×")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary.opacity(0.8))
            )
            let labelSize = label.measure(in: CGSize(width: 200, height: 40))
            let pill = CGRect(x: rect.minX + 5, y: rect.minY + 5, width: labelSize.width + 10, height: labelSize.height + 4)
            if pill.maxX < rect.maxX - 3 {
                context.fill(Path(roundedRect: pill, cornerRadius: pill.height / 2), with: .color(tint.opacity(0.22)))
                context.draw(label, at: CGPoint(x: pill.midX, y: pill.midY))
            }

            if !["speech", "quiet", "gap", ""].contains(segment.note), rect.width > 50 {
                let line = CGRect(x: rect.minX + 6, y: rect.maxY - 18, width: rect.width - 12, height: 14)
                context.drawLayer { layer in
                    layer.clip(to: Path(line))
                    layer.draw(Text(segment.note).font(.caption2).foregroundStyle(.secondary),
                               at: CGPoint(x: line.minX, y: line.midY), anchor: .leading)
                }
            }
        }

        let step = [1.0, 2, 5, 10, 15, 30, 60, 120, 300, 600].first { CGFloat($0 / duration) * size.width >= 60 } ?? 600
        var tick = 0.0
        var lastLabel = -CGFloat.infinity
        while tick <= duration {
            let position = x(tick)
            context.fill(Path(CGRect(x: position, y: lane.maxY + 2, width: 1, height: 3)), with: .color(.secondary.opacity(0.6)))
            if position - lastLabel >= 40 {
                context.draw(Text(clock(tick).replacingOccurrences(of: ".0", with: "")).font(.caption2).foregroundStyle(.tertiary),
                             at: CGPoint(x: position + 3, y: lane.maxY + 3), anchor: .topLeading)
                lastLabel = position
            }
            tick += step
        }

        let head = x(playhead)
        context.fill(Path(CGRect(x: head - 1, y: 0, width: 2, height: lane.height)), with: .color(.red))
        context.fill(Path(ellipseIn: CGRect(x: head - 4, y: -1, width: 8, height: 8)), with: .color(.red))
    }
}
