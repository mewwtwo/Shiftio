import SwiftUI

/// An annular sector with an even gap to its neighbours and rounded corners.
struct RingSegmentShape: Shape {
    /// Doubles so SwiftUI can animate between rings with a different number of segments: the sector slides
    /// and resizes instead of the glass being rebuilt.
    var index: Double
    var count: Double
    var innerRatio: CGFloat = 0.4

    init(index: Int, count: Int, innerRatio: CGFloat = 0.4) {
        self.index = Double(index)
        self.count = Double(count)
        self.innerRatio = innerRatio
    }

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(index, count) }
        set { (index, count) = (newValue.first, newValue.second) }
    }
    var gap: CGFloat = 8
    var cornerRadius: CGFloat = 14

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * innerRatio
        let point = { (angle: Double, radius: CGFloat) in RadialGeometry.point(angle: angle, radius: radius, center: center) }

        guard count > 1.05 else {
            var ring = Path(ellipseIn: CGRect(x: center.x - outer, y: center.y - outer, width: outer * 2, height: outer * 2))
            ring.addEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
            return ring
        }

        let span = 2 * .pi / count
        let mid = index * span
        // Constant-width gaps: the angular inset differs on each arc.
        let outerStart = mid - span / 2 + Double(gap / 2 / outer), outerEnd = mid + span / 2 - Double(gap / 2 / outer)
        let innerStart = mid - span / 2 + Double(gap / 2 / inner), innerEnd = mid + span / 2 - Double(gap / 2 / inner)
        let outerCorner = min(cornerRadius, outer * CGFloat(outerEnd - outerStart) / 3)
        let innerCorner = min(cornerRadius * 0.7, inner * CGFloat(innerEnd - innerStart) / 3)
        let outerInset = Double(outerCorner / outer), innerInset = Double(innerCorner / inner)

        var path = Path()
        let p1 = point(outerStart, outer), p2 = point(outerEnd, outer)
        let p3 = point(innerEnd, inner), p4 = point(innerStart, inner)

        path.move(to: CGPoint(x: (p1.x + p4.x) / 2, y: (p1.y + p4.y) / 2))
        path.addArc(tangent1End: p1, tangent2End: point(outerStart + 2 * outerInset, outer), radius: outerCorner)
        addArc(to: &path, from: outerStart + outerInset, to: outerEnd - outerInset, radius: outer, center: center)
        path.addArc(tangent1End: p2, tangent2End: p3, radius: outerCorner)
        path.addArc(tangent1End: p3, tangent2End: point(innerEnd - 2 * innerInset, inner), radius: innerCorner)
        addArc(to: &path, from: innerEnd - innerInset, to: innerStart + innerInset, radius: inner, center: center)
        path.addArc(tangent1End: p4, tangent2End: p1, radius: innerCorner)
        path.closeSubpath()
        return path
    }

    /// Arcs as polylines so the direction convention can't flip between coordinate systems.
    private func addArc(to path: inout Path, from start: Double, to end: Double, radius: CGFloat, center: CGPoint) {
        let steps = max(8, Int(abs(end - start) * 24))
        for step in 0...steps {
            let angle = start + (end - start) * Double(step) / Double(steps)
            path.addLine(to: RadialGeometry.point(angle: angle, radius: radius, center: center))
        }
    }
}
