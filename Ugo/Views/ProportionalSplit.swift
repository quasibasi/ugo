import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Views side by side or stacked, each sized as a share of the whole, so a
/// resized container keeps their proportions. The gutters between them drag.
/// The built-in split views hand a size change to one child instead.
struct ProportionalSplit<Item: Identifiable, Content: View>: View {
    let axis: Axis
    let items: [Item]
    /// One share per item, in order. Any scale: they are normalised before use.
    @Binding var fractions: [Double]
    /// The smallest size a drag leaves a view. A small container may still go below it.
    let minimum: CGFloat
    @ViewBuilder let content: (Int, Item) -> Content

    /// Width of the strip between two views: a hairline with room to grab it.
    static var gutter: CGFloat { 7 }

    @State private var dragStart: [Double]?
    @State private var live: [Double]?

    var body: some View {
        GeometryReader { geometry in
            let total = axis == .horizontal ? geometry.size.width : geometry.size.height
            let sizes = Self.sizes(total: total, shares: live ?? fractions, count: items.count)
            let stack = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            stack {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    content(index, item)
                        .frame(width: axis == .horizontal ? sizes[index] : nil, height: axis == .vertical ? sizes[index] : nil)
                    if index < items.count - 1 {
                        gutter(after: index, total: total)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }

    private func gutter(after index: Int, total: CGFloat) -> some View {
        Rectangle()
            .fill(.separator)
            .frame(width: axis == .horizontal ? 1 : nil, height: axis == .vertical ? 1 : nil)
            .frame(width: axis == .horizontal ? Self.gutter : nil, height: axis == .vertical ? Self.gutter : nil)
            .frame(maxWidth: axis == .vertical ? .infinity : nil, maxHeight: axis == .horizontal ? .infinity : nil)
            .contentShape(Rectangle())
            #if os(macOS)
            .onHover { inside in
                if inside {
                    (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            #endif
            .gesture(drag(after: index, total: total))
    }

    /// Moves the boundary between view `index` and the next one, keeping both at least `minimum`.
    private func drag(after index: Int, total: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? Self.normalized(fractions, count: items.count)
                if dragStart == nil { dragStart = start }
                let available = Self.available(total: total, count: items.count)
                guard available > 0, index + 1 < start.count else { return }
                let delta = axis == .horizontal ? value.translation.width : value.translation.height
                let first = CGFloat(start[index]) * available
                let second = CGFloat(start[index + 1]) * available
                let move = min(max(delta, -max(0, first - minimum)), max(0, second - minimum))
                var shares = start
                shares[index] = Double((first + move) / available)
                shares[index + 1] = Double((second - move) / available)
                live = shares
            }
            .onEnded { _ in
                if let live { fractions = live }
                dragStart = nil
                live = nil
            }
    }

    private static func available(total: CGFloat, count: Int) -> CGFloat {
        max(0, total - CGFloat(max(0, count - 1)) * gutter)
    }

    private static func normalized(_ shares: [Double], count: Int) -> [Double] {
        let sum = shares.reduce(0, +)
        guard shares.count == count, sum > 0 else { return Array(repeating: 1 / Double(max(count, 1)), count: count) }
        return shares.map { $0 / sum }
    }

    /// Whole points each, with the rounding remainder on the last view so the sizes fill the axis.
    private static func sizes(total: CGFloat, shares: [Double], count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        let available = available(total: total, count: count)
        var sizes = normalized(shares, count: count).map { (CGFloat($0) * available).rounded(.down) }
        sizes[count - 1] += available - sizes.reduce(0, +)
        return sizes
    }
}
