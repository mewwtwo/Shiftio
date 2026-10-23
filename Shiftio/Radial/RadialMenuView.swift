import SwiftUI

/// The ring. Every piece of glass appears, disappears and switches through Liquid Glass's own
/// `materialize` transition inside one `GlassEffectContainer`. Fading, rotating or scaling a glass view as a
/// group makes SwiftUI flatten it into a rectangular plate, so none of that is applied to glass here.
struct RadialMenuView: View {
    let state: RadialState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glassSpace

    var body: some View {
        let geometry = state.geometry
        let motion: Animation = reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.42, dampingFraction: 0.82)

        GlassEffectContainer(spacing: 0) {
            VStack(spacing: 0) {
                ZStack {
                    if state.isVisible, state.committed == nil, state.rings.count > 1 {
                        RingPager(state: state, space: glassSpace)
                    }
                }
                .frame(height: RadialGeometry.pagerHeight)

                // Every ring renders its glass in a container of its own, so the old and new ring never blend.
                GlassEffectContainer(spacing: 0) {
                    RingView(state: state, geometry: geometry)
                }
                .id(state.ring?.id)
                .frame(width: geometry.diameter, height: geometry.diameter)
                .padding(RadialGeometry.padding)
            }
        }
        .frame(width: geometry.panelSize.width, height: geometry.panelSize.height)
        .animation(motion, value: state.isVisible)
        // Ring changes (switching, a tile's options, back) reshape the same glass smoothly and without overshoot,
        // so wedges never briefly come out uneven.
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.3), value: state.ring?.id)
        .animation(.easeOut(duration: 0.18), value: state.committed)
        .environment(\.glassSettings, state.appearance.glass)
        // The panel never activates the app, so without this the glass and controls would switch to their grey inactive look.
        .environment(\.controlActiveState, .key)
    }
}

private struct Slot: Identifiable {
    let id: String
    let index: Int
    let item: RingItem
}

private struct RingView: View {
    let state: RadialState
    let geometry: RadialGeometry
    @Namespace private var space
    /// A ring that replaces another one starts empty and materializes a beat later inside its fresh container.
    /// A ring being opened (not yet visible) needs no such step: `isVisible` already makes it materialize.
    @State private var appeared: Bool

    init(state: RadialState, geometry: RadialGeometry) {
        self.state = state
        self.geometry = geometry
        _appeared = State(initialValue: !state.isVisible)
    }

    private var tint: Color { state.appearance.accent }

    var body: some View {
        let ringID = state.ring?.id.uuidString ?? "none"
        // Each ring has its own glass: switching rings materializes the new ring's glass and dissolves the old one's.
        let slots = (state.ring?.segments ?? []).enumerated().map { Slot(id: "\(ringID)-\($1.id)", index: $0, item: $1) }
        let innerRatio = geometry.innerRadius / geometry.outerRadius
        let shown = state.isVisible && appeared

        ZStack {
            ForEach(slots) { slot in
                let hover = RadialHover.segment(slot.index)
                let isHovered = state.hover == hover
                let isDimmed = state.committed != nil && state.committed != hover
                let shape = RingSegmentShape(index: slot.index, count: slots.count, innerRatio: innerRatio)

                if shown, !isDimmed {
                    // The label is the glass view's *content*: a sibling inside the container would be covered by the glass.
                    ZStack {
                        shape.fill(tint.opacity(isHovered ? 0.62 : 0))
                        shape.stroke(.white.opacity(isHovered ? 0.85 : 0), lineWidth: 1.5)
                        SegmentLabel(item: slot.item, appearance: state.appearance, isHovered: isHovered,
                                     scale: geometry.contentScale * geometry.textDensity, maxWidth: geometry.labelMaxWidth)
                            .id(ringID + slot.item.id)
                            .transition(.opacity)
                            .offset(labelOffset(slot.index))
                    }
                    .adaptiveGlass(tint: tint, tintAmount: 1, interactive: true, in: shape)
                    .glassEffectID(slot.id, in: space)
                    .glassEffectTransition(.materialize)
                    // The hovered petal lifts straight up, like a key being pressed toward you, never sideways.
                    .offset(y: state.committed == hover ? -11 * geometry.contentScale : (isHovered ? -8 * geometry.contentScale : 0))
                    .animation(.smooth(duration: 0.18), value: isHovered)
                    .accessibilityLabel(slot.item.title)
                }
            }

            if shown, state.committed == nil, let center = state.ring?.center {
                let isHovered = state.hover == .center
                SegmentLabel(item: center, appearance: state.appearance, isHovered: isHovered, compact: true,
                             scale: geometry.contentScale, maxWidth: geometry.innerRadius * 1.5)
                    // Hugs its text, so a short "‹ Folders" is a small pill rather than a wide bar.
                    .padding(.horizontal, 12 * geometry.contentScale)
                    .frame(minHeight: 28 * geometry.contentScale)
                    .background { Capsule().fill(tint.opacity(isHovered ? 0.62 : 0)) }
                    .adaptiveGlass(tint: tint, tintAmount: 2, interactive: true, in: Capsule())
                    .glassEffectID("center-\(ringID)", in: space)
                    .glassEffectTransition(.materialize)
                    .offset(y: isHovered ? -5 * geometry.contentScale : 0)
                    .animation(.smooth(duration: 0.18), value: isHovered)
            }
        }
        .task {
            guard !appeared else { return }
            try? await Task.sleep(for: .milliseconds(60))
            withAnimation(.smooth(duration: 0.4)) { appeared = true }
        }
    }

    private func labelOffset(_ index: Int) -> CGSize {
        let point = RadialGeometry.point(angle: geometry.centerAngle(of: index), radius: geometry.labelRadius)
        return CGSize(width: point.x, height: point.y)
    }
}

private struct SegmentLabel: View {
    let item: RingItem
    let appearance: Appearance
    let isHovered: Bool
    var compact = false
    let scale: CGFloat
    let maxWidth: CGFloat
    @Environment(\.glassSettings) private var glass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    /// Clear glass is dimmed dark in the dark appearance, so its text is white there; in the light one it is pearl and the text is dark.
    private var restingStyle: AnyShapeStyle { glass.style == .clear && !reduceTransparency && colorScheme == .dark ? AnyShapeStyle(.white) : AnyShapeStyle(.primary) }

    var body: some View {
        VStack(spacing: (item.image != nil || item.emoji != nil ? 9 : 5) * scale) {
            if appearance.showIcons, !compact {
                if let image = item.image {
                    Image(nsImage: image).resizable().interpolation(.high)
                        .frame(width: 26 * scale, height: 26 * scale)
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                } else if let emoji = item.emoji {
                    Text(emoji).font(.system(size: 22 * scale))
                } else if let symbol = item.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 17 * scale, weight: .medium))
                        .symbolVariant(isHovered ? .fill : .none)
                }
            }
            if appearance.showLabels || (item.symbol == nil && item.image == nil && item.emoji == nil) || compact {
                Text(item.title.uppercased())
                    .font(.system(size: 11 * scale, weight: .bold))
                    .tracking(0.5 * scale)
                    .multilineTextAlignment(.center)
                    // Two-word names wrap onto two lines; anything still too wide shrinks instead of spilling over.
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: maxWidth)
        .foregroundStyle(isHovered ? AnyShapeStyle(.white) : restingStyle)
        // A soft shadow keeps the text readable when clear glass sits over a bright wallpaper.
        .shadow(color: colorScheme == .dark || isHovered ? .black.opacity(0.45) : .clear, radius: 2.5, y: 1)
        .animation(.smooth(duration: 0.16), value: isHovered)
    }
}

/// Ring names on top; one highlight slides to the current name. Only shown with more than one ring.
private struct RingPager: View {
    let state: RadialState
    let space: Namespace.ID
    @Namespace private var namespace
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // On pearl glass the names are dark: white on a pale accent, or gray on white, is hard to read.
        let dark = colorScheme == .dark
        if state.rings.count > 1 {
            HStack(spacing: 2) {
                ForEach(Array(state.rings.enumerated()), id: \.element.id) { index, ring in
                    let isCurrent = index == state.ringIndex
                    Text(ring.name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(isCurrent ? (dark ? AnyShapeStyle(.white) : AnyShapeStyle(.primary)) : (dark ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary.opacity(0.7))))
                        .frame(minWidth: 58, minHeight: 24)
                        .padding(.horizontal, 6)
                        .background {
                            // The selected name is a piece of tinted glass of its own, sliding between names.
                            if isCurrent {
                                Color.clear
                                    .adaptiveGlass(tint: state.appearance.accent, tintAmount: 6, interactive: true, in: Capsule())
                                    .matchedGeometryEffect(id: "current", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                Rectangle().fill(.primary.opacity(0.18)).frame(width: 1, height: 14).padding(.horizontal, 5)
                Image(systemName: "shift")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(dark ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary.opacity(0.7)))
                    .padding(.trailing, 8)
            }
            .padding(3)
            .adaptiveGlass(in: Capsule())
            .glassEffectID("pager", in: space)
            .glassEffectTransition(.materialize)
            .animation(.spring(response: 0.38, dampingFraction: 0.8), value: state.ringIndex)
        }
    }
}
