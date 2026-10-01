import SwiftUI
import AppKit

/// Thin draggable divider that resizes one pane as a fraction of the available space.
/// - `.vertical`: a vertical bar between left and right panes (drag horizontally).
/// - `.horizontal`: a horizontal bar between top and bottom panes (drag vertically).
/// `growsWithDrag`: true if dragging right/down should grow the pane the fraction describes.
struct SplitHandle: View {
    enum Axis { case vertical, horizontal }

    let axis: Axis
    let total: CGFloat
    @Binding var fraction: Double
    let range: ClosedRange<Double>
    let growsWithDrag: Bool

    @State private var startFraction: Double?

    var body: some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
        }
        .frame(width: axis == .vertical ? 7 : nil, height: axis == .horizontal ? 7 : nil)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                (axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if startFraction == nil { startFraction = fraction }
                    let delta = (axis == .vertical ? value.translation.width : value.translation.height) / max(total, 1)
                    let proposed = (startFraction ?? fraction) + Double(growsWithDrag ? delta : -delta)
                    fraction = min(max(proposed, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in startFraction = nil }
        )
    }
}
