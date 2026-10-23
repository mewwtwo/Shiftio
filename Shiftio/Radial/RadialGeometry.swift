import CoreGraphics
import SwiftUI
import Foundation

/// Angles are measured clockwise from 12 o'clock, in a top-left-origin (flipped) space.
/// Segment 0 is centred at the top.
struct RadialGeometry {
    let diameter: CGFloat
    let segmentCount: Int
    let hasCenter: Bool

    static let pagerHeight: CGFloat = 40
    static let padding: CGFloat = 14

    var outerRadius: CGFloat { diameter / 2 }
    /// Large enough for a dragged file icon, small enough that the ring doesn't look hollow.
    var innerRadius: CGFloat { diameter * 0.2 }
    /// Labels sit a little beyond the middle of the band, where a segment is wider.
    var labelRadius: CGFloat { innerRadius + (outerRadius - innerRadius) * 0.5 }

    /// Crowded rings get slightly smaller type so names fit their segment.
    var textDensity: CGFloat {
        switch segmentCount {
        case ...6: 1
        case 7...8: 0.92
        default: 0.84
        }
    }
    var span: Double { 2 * .pi / Double(max(segmentCount, 1)) }

    /// Type and icons scale with the ring (340 pt is the reference size).
    var contentScale: CGFloat { diameter / 340 }

    /// Widest a label may be inside its segment: the chord at the label radius, minus margin for gaps and corners.
    var labelMaxWidth: CGFloat {
        segmentCount > 1 ? 2 * labelRadius * CGFloat(sin(span / 2)) * 0.86 : outerRadius * 1.2
    }

    /// Size of the panel content: pager on top, then the ring with padding.
    var panelSize: CGSize {
        CGSize(width: diameter + 2 * Self.padding, height: Self.pagerHeight + diameter + 2 * Self.padding)
    }

    /// Ring centre inside the panel content (flipped coordinates).
    var ringCenter: CGPoint {
        CGPoint(x: panelSize.width / 2, y: Self.pagerHeight + Self.padding + diameter / 2)
    }

    func centerAngle(of index: Int) -> Double { Double(index) * span }

    static func point(angle: Double, radius: CGFloat, center: CGPoint = .zero) -> CGPoint {
        CGPoint(x: center.x + CGFloat(sin(angle)) * radius, y: center.y - CGFloat(cos(angle)) * radius)
    }

    func isInHole(_ point: CGPoint) -> Bool {
        let dx = point.x - ringCenter.x, dy = point.y - ringCenter.y
        return (dx * dx + dy * dy).squareRoot() < innerRadius
    }

    /// Like `hit(_:)`, but stays on `current` until the pointer is clearly past the boundary, so hovering
    /// along the edge between two segments doesn't flicker between them.
    func hit(_ point: CGPoint, keeping current: RadialHover?) -> RadialHover? {
        let raw = hit(point)
        guard case .segment(let kept)? = current, case .segment(let found)? = raw, kept != found, segmentCount > 1 else { return raw }
        let dx = Double(point.x - ringCenter.x), dy = Double(point.y - ringCenter.y)
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        var delta = abs(angle - centerAngle(of: kept)).truncatingRemainder(dividingBy: 2 * .pi)
        if delta > .pi { delta = 2 * .pi - delta }
        return delta < span / 2 + 0.06 ? current : raw
    }

    /// Where a segment's visual centre sits inside the ring's square, as a unit point (for scaling it in place).
    func anchor(of index: Int) -> UnitPoint {
        let a = centerAngle(of: index)
        return UnitPoint(x: 0.5 + sin(a) * labelRadius / diameter, y: 0.5 - cos(a) * labelRadius / diameter)
    }

    func hit(_ point: CGPoint) -> RadialHover? {
        let dx = point.x - ringCenter.x, dy = point.y - ringCenter.y
        let distance = (dx * dx + dy * dy).squareRoot()
        if distance < innerRadius { return hasCenter ? .center : nil }
        guard distance <= outerRadius + Self.padding, segmentCount > 0 else { return nil }

        var angle = atan2(Double(dx), Double(-dy)) + span / 2
        if angle < 0 { angle += 2 * .pi }
        return .segment(Int(angle / span) % segmentCount)
    }
}

enum RadialHover: Equatable {
    case center
    case segment(Int)
}
