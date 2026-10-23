import Foundation
import Observation

@MainActor @Observable
final class RadialState {
    var rings: [ResolvedRing] = []
    var ringIndex = 0
    var hover: RadialHover?
    /// Segment that just received a drop; it pops while the rest of the ring fades.
    var committed: RadialHover?
    var isVisible = false
    var appearance = Appearance()

    var ring: ResolvedRing? { rings.indices.contains(ringIndex) ? rings[ringIndex] : nil }

    var geometry: RadialGeometry {
        RadialGeometry(diameter: appearance.diameter, segmentCount: ring?.segments.count ?? 0,
                       hasCenter: ring?.center != nil)
    }

    func item(for hover: RadialHover) -> RingItem? {
        switch hover {
        case .center: ring?.center
        case .segment(let index): ring?.segments.indices.contains(index) == true ? ring?.segments[index] : nil
        }
    }

    func nextRing() {
        guard rings.count > 1 else { return }
        ringIndex = (ringIndex + 1) % rings.count
        hover = nil
    }
}
