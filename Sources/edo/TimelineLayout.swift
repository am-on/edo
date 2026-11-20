import CoreGraphics

/// Maps video time to timeline position so every segment is at least `minWidth` wide;
/// inside a segment, time stays linear.
struct TimelineLayout {
    private let spans: [(start: Double, end: Double)]
    private let offsets: [CGFloat]
    private let widths: [CGFloat]
    let width: CGFloat

    init(plan: Plan, duration: Double, width: CGFloat, minWidth: CGFloat = 28) {
        var spans = plan.segments.map { (start: $0.start, end: $0.end) }
        if let last = spans.indices.last, duration - spans[last].end < 0.05 {
            spans[last].end = max(spans[last].end, duration)
        } else {
            spans.append((start: spans.last?.end ?? 0, end: max(duration, (spans.last?.end ?? 0) + 0.001)))
        }
        let durations = spans.map { $0.end - $0.start }
        var floor = minWidth
        if CGFloat(spans.count) * minWidth > width { floor = 0 }

        var pinned = Set<Int>()
        var widths = [CGFloat](repeating: 0, count: spans.count)
        while true {
            let free = width - floor * CGFloat(pinned.count)
            let freeDuration = durations.indices.filter { !pinned.contains($0) }.reduce(0) { $0 + durations[$1] }
            var newlyPinned = false
            for i in durations.indices where !pinned.contains(i) {
                widths[i] = freeDuration > 0 ? CGFloat(durations[i] / freeDuration) * free : 0
                if widths[i] < floor {
                    pinned.insert(i)
                    newlyPinned = true
                }
            }
            if !newlyPinned { break }
        }
        for i in pinned { widths[i] = floor }

        var offsets: [CGFloat] = []
        var x: CGFloat = 0
        for w in widths {
            offsets.append(x)
            x += w
        }
        self.spans = spans
        self.offsets = offsets
        self.widths = widths
        self.width = width
    }

    func x(_ time: Double) -> CGFloat {
        guard let i = spans.lastIndex(where: { $0.start <= time }) else { return 0 }
        let span = spans[i]
        let fraction = min(max((time - span.start) / (span.end - span.start), 0), 1)
        return offsets[i] + CGFloat(fraction) * widths[i]
    }

    func time(_ x: CGFloat) -> Double {
        guard let i = offsets.lastIndex(where: { $0 <= x }) else { return spans.first?.start ?? 0 }
        let span = spans[i]
        let fraction = widths[i] > 0 ? Double(min(max((x - offsets[i]) / widths[i], 0), 1)) : 0
        return span.start + fraction * (span.end - span.start)
    }
}
