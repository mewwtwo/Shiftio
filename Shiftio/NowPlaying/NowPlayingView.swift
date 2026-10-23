import SwiftUI

/// The player above the System ring. Like the ring, it is not one big plate but several small pieces of Liquid Glass in
/// one container (the cover, the title, the buttons, the bar, and below them the lyrics or queue), so each piece bends
/// the light at its own edge and materializes the same way the petals do. Nothing inside the glass is faded or scaled.
struct NowPlayingView: View {
    let service: NowPlayingService
    let appearance: Appearance

    static let width: CGFloat = 350

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glassSpace
    @State private var gripHovered = false

    var body: some View {
        let motion: Animation = reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.42, dampingFraction: 0.82)
        let change: Animation = reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.3)
        ZStack {
            // An invisible copy gives the panel its size from the first moment, and again whenever the layout changes.
            // It is never animated, so the panel is not measured halfway through a transition.
            layout(glass: false).opacity(0).allowsHitTesting(false).accessibilityHidden(true)
                .transaction { $0.animation = nil }
            GlassEffectContainer(spacing: 0) {
                if service.isShown { layout(glass: true) }
            }
            .animation(motion, value: service.isShown)
            .animation(change, value: service.expanded)
            .animation(change, value: service.pane)
            .animation(change, value: service.hasQueue)
            .animation(change, value: service.isPinned)
        }
        .environment(\.glassSettings, appearance.glass)
        .environment(\.controlActiveState, .key)
    }

    private let gap: CGFloat = 5

    private func piece<Content: View, S: Shape>(_ id: String, _ shape: S, glass: Bool, height: CGFloat? = nil, dim: Bool = true,
                                                @ViewBuilder content: () -> Content) -> some View {
        GlassPiece(id: id, shape: shape, glass: glass, height: height, dim: dim, isKey: service.isKey, space: glassSpace, tint: service.isKey ? appearance.accent : nil, content: content())
    }

    @ViewBuilder
    private func layout(glass: Bool) -> some View {
        if let track = service.track {
            VStack(spacing: gap) {
                // A pinned player is dragged by this grip: only the bar shows, with no plate under it. The body under the bar is painted
                // at 1% so the window still catches the mouse; fully clear pixels let it go through to the desktop.
                if service.isPinned {
                    ZStack {
                        Color.black.opacity(0.01)
                        GripView(movesWindow: true, onRelease: { service.releaseVelocity = $0 }, onDragState: { service.isDragging = $0; if !$0 { service.onDragEnd() } }, onHover: { gripHovered = $0 }) {}
                        // Shown only while the pointer is over the grip (or it is being dragged).
                        Capsule().fill(.white.opacity(0.75)).frame(width: 40, height: 4).allowsHitTesting(false)
                            .opacity(gripHovered || service.isDragging ? 1 : 0)
                            .animation(.easeOut(duration: 0.15), value: gripHovered)
                    }
                    .frame(width: 108, height: 12)
                    .padding(.bottom, -4)
                    .help("Drag to move the player")
                    .transition(.opacity)
                }
                HStack(spacing: gap) {
                    Button { service.openAppAndClose() } label: { CoverView(image: service.cover) }
                        .buttonStyle(PressStyle(hoverScale: 1.07, tapsOnEnter: true))
                        .frame(width: 64, height: 64)
                        .help("Open \(track.source.name)")
                    piece("title", RoundedRectangle(cornerRadius: 22, style: .continuous), glass: glass, height: 60) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                            Text(track.artist).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.75)).lineLimit(1)
                            Text(track.source.name).font(.system(size: 10, weight: .medium)).foregroundStyle(.primary.opacity(0.5))
                        }
                        .shadow(color: .black.opacity(0.45), radius: 1.5, y: 0.5)
                        .id(track.title + track.artist)
                        .transition(.blurReplace)
                        .padding(.leading, 14).padding(.trailing, service.isMini || service.isPinned ? 62 : 36)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .contentShape(.rect)
                        .onTapGesture { service.toggleExpanded() }
                        .overlay(alignment: .topTrailing) {
                            headerButtons
                            .padding(6)
                        }
                    }
                }
                HStack(spacing: gap) {
                    piece("controls", Capsule(), glass: glass, height: 46) {
                        HStack(spacing: 0) {
                            transport("backward.fill", size: 14) { service.previous() }
                            transport(track.isPlaying ? "pause.fill" : "play.fill", size: 19) { service.playPause() }
                            transport("forward.fill", size: 14) { service.next() }
                        }
                        .padding(.horizontal, 8)
                        .frame(maxHeight: .infinity)
                    }
                    piece("bar", Capsule(), glass: glass, height: 46) {
                        TrackBar(track: track, live: glass, interval: service.isPinned ? 1 : 0.5) { service.seek(toFraction: $0) }
                            .padding(.horizontal, 16)
                            .frame(maxHeight: .infinity)
                    }
                }
                if service.expanded {
                    piece("pane", RoundedRectangle(cornerRadius: 24, style: .continuous), glass: glass) {
                        paneBody(track, glass: glass)
                        .padding(12)
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(width: Self.width)
        } else if let streamer = service.needsPermission {
            piece("permission", RoundedRectangle(cornerRadius: 24, style: .continuous), glass: glass) {
                HStack(spacing: 12) {
                    Image(systemName: "music.note").font(.system(size: 20)).frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(streamer.name) is open").font(.system(size: 13, weight: .semibold))
                        Text("Allow Shiftio to see and control playback.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Allow") { service.allow(streamer) }.buttonStyle(.borderedProminent).controlSize(.small)
                }
                .padding(12)
                .frame(width: Self.width)
            }
        }
    }

    private var headerButtons: some View {
        HStack(spacing: 0) {
            // With only the player on screen it can be pinned: it then stays until unpinned.
            if service.isMini || service.isPinned {
                Button { service.togglePin() } label: {
                    Image(systemName: service.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(.rect)
                }
                .buttonStyle(PressStyle(hoverScale: 1.2))
                .help(service.isPinned ? "Unpin" : "Pin the player on screen")
                .transition(.opacity)
            }
            // Keeps only this player on screen and closes the ring.
            Button { service.onDetach() } label: {
                Image(systemName: service.isMini ? "pip.exit" : "pip.enter")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(.rect)
            }
            .buttonStyle(PressStyle(hoverScale: 1.2))
            .help(service.isMini ? "Bring the ring back" : "Keep only the player")
        }
    }

    private func paneBody(_ track: NowPlayingTrack, glass: Bool) -> some View {
        VStack(spacing: 8) {
            if service.hasQueue { PaneSwitch(service: service) }
            switch service.pane {
            case .lyrics:
                if glass { LyricsView(state: service.lyrics, track: track, height: service.paneHeight) { service.seek(toSeconds: $0) } }
                else { Color.clear.frame(height: service.paneHeight) }
            case .queue: QueueView(items: service.queue, note: service.queueNote, height: service.paneHeight) { service.play($0) }
            }
        }
    }

    private func transport(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 38, height: 38)
                .contentShape(.rect)
        }
        .buttonStyle(PressStyle(hoverScale: 1.18))
    }
}

/// Grows a little under the pointer and dips when pressed. Applied to the button's content only, never to glass.
private struct PressStyle: ButtonStyle {
    var hoverScale: CGFloat = 1.1
    /// Only the cover, which is a tile of its own, gives the trackpad tap; the buttons inside a plate do not.
    var tapsOnEnter = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : (hovering ? hoverScale : 1))
            .onHover { inside in
                hovering = inside
                if inside && tapsOnEnter { Haptics.hover() }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.68), value: hovering)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// One piece of glass. Under the pointer it grows by a few points (its size changes, nothing is scaled, so the glass stays
/// sharp), inside a frame that already has room for that, so its neighbours never move. In the invisible copy it is only a frame.
private struct GlassPiece<Content: View, S: Shape>: View {
    @Environment(\.colorScheme) private var colorScheme
    let id: String
    let shape: S
    let glass: Bool
    let height: CGFloat?
    var dim = true
    var isKey = true
    let space: Namespace.ID
    /// Left out while the window is not key, so the glass takes its colour from what is behind it instead of a tint.
    let tint: Color?
    let content: Content
    @State private var hovering = false

    private let room: CGFloat = 4

    var body: some View {
        let grown = glass && hovering
        let sized = content.frame(height: height.map { $0 + (grown ? room : 0) })
        Group {
            if glass {
                sized
                    .padding(.horizontal, grown ? 0 : room / 2)
                    // A little more dimming than the ring's petals have, because these hold text that has to stay readable
                    // over a busy desktop.
                    // Less dimming when the window is not key: the glass is then drawn flat, and a dark plate under it would
                    // make it look like plastic.
                    .background { if dim { shape.fill(colorScheme == .dark ? Color.black.opacity(isKey ? 0.2 : 0.06) : Color.white.opacity(isKey ? 0.4 : 0.25)) } }
                    .adaptiveGlass(tint: tint, tintAmount: 1, in: shape)
                    .glassEffectID(id, in: space)
                    .glassEffectTransition(.materialize)
                    // What the system leaves out of inactive glass: a bright curved edge and a soft highlight across the top.
                    .overlay {
                        if !isKey {
                            ZStack {
                                shape.stroke(.white.opacity(0.28), lineWidth: 0.8)
                                shape.fill(LinearGradient(colors: [.white.opacity(0.12), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.5)))
                            }
                            .allowsHitTesting(false)
                        }
                    }
            } else {
                sized.padding(.horizontal, room / 2)
            }
        }
        .frame(height: height.map { $0 + room })
        .contentShape(.rect)
        .onHover { inside in
            hovering = inside
            if inside && glass { Haptics.hover() }
        }
        .animation(.smooth(duration: 0.18), value: hovering)
    }
}

private struct CoverView: View {
    let image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Rectangle().fill(.white.opacity(0.12))
                Image(systemName: "music.note").font(.system(size: 20)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 60, height: 60)
        .clipShape(.rect(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.3), lineWidth: 0.8) }
        .contentShape(.rect(cornerRadius: 18, style: .continuous))
        .transition(.opacity)
    }
}

/// The track from start to end. A click or drag anywhere on it jumps there, and the time under the finger is shown while it moves.
private struct TrackBar: View {
    @Environment(\.colorScheme) private var colorScheme
    let track: NowPlayingTrack
    /// The invisible copy that only sizes the panel does not tick.
    var live = true
    /// How often the bar moves. Each tick redraws a piece of glass, which is costly while the player stays on screen.
    var interval: Double = 0.5
    let onSeek: (Double) -> Void
    @State private var dragging: Double?
    private var ink: Color { colorScheme == .dark ? .white : Color(white: 0.2) }

    var body: some View {
        TimelineView(live ? .animation(minimumInterval: interval, paused: !track.isPlaying && dragging == nil) : .animation(minimumInterval: 3600, paused: true)) { context in
            let length = max(track.duration, 0.001)
            let fraction = dragging ?? min(1, track.position(at: context.date) / length)
            VStack(spacing: 3) {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(ink.opacity(0.22))
                        Capsule().fill(ink.opacity(0.9)).frame(width: max(6, width * fraction))
                        Circle().fill(ink).frame(width: dragging == nil ? 0 : 12, height: dragging == nil ? 0 : 12)
                            .offset(x: width * fraction - 6)
                    }
                    .frame(height: dragging == nil ? 5 : 7)
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { drag in dragging = min(max(drag.location.x / width, 0), 1) }
                        .onEnded { drag in
                            onSeek(min(max(drag.location.x / width, 0), 1))
                            dragging = nil
                        })
                    .animation(.easeOut(duration: 0.12), value: dragging == nil)
                }
                .frame(height: 16)
                HStack {
                    Text(Self.format(fraction * length))
                    Spacer()
                    Text("-" + Self.format((1 - fraction) * length))
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
        .disabled(track.duration <= 0)
    }

    private static func format(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}


/// Lyrics that follow the song: with timed lyrics the line being sung is bright and the list scrolls to keep it in the
/// middle; a tap on any timed line jumps there. Without timing the lyrics are plain text to scroll by hand.
private struct LyricsView: View {
    let state: LyricsState
    let track: NowPlayingTrack
    let height: CGFloat
    let onSeek: (Double) -> Void

    var body: some View {
        switch state {
        case .idle, .loading:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: height)
        case .missing:
            Text("No lyrics found for this track.").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: height)
        case .found(let lines):
            let timed = lines.contains { $0.time != nil }
            TimelineView(.animation(minimumInterval: 0.4, paused: !track.isPlaying)) { context in
                // A line is shown a moment before it is sung, as lyric apps do, and the check runs often enough not to add delay.
                let now = track.position(at: context.date) + 0.35
                let current = timed ? lines.last { ($0.time ?? .infinity) <= now }?.id : nil
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(lines) { line in
                                LyricLineView(line: line, distance: current.map { abs($0 - line.id) }, isTimed: timed) {
                                    if let time = line.time { onSeek(time) }
                                }
                                .id(line.id)
                            }
                        }
                        .padding(.vertical, height / 2.4)
                    }
                    .scrollIndicators(.hidden)
                    .onAppear { if let current { reader.scrollTo(current, anchor: .center) } }
                    .onChange(of: current) { _, id in
                        if let id { withAnimation(.smooth(duration: 0.5)) { reader.scrollTo(id, anchor: .center) } }
                    }
                }
            }
            .frame(height: height)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18),
                                         .init(color: .black, location: 0.82), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
        }
    }
}

private struct LyricLineView: View {
    let line: LyricLine
    /// How many lines away from the one being sung; nil when the lyrics have no timing.
    let distance: Int?
    let isTimed: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let isCurrent = distance == 0
        let emphasis: Double = distance.map { $0 == 0 ? 1 : max(0.3, 0.62 - Double($0) * 0.08) } ?? 0.9
        Button(action: action) {
            Text(line.text.isEmpty ? "♪" : line.text)
                .font(.system(size: 16, weight: .bold))
                .shadow(color: .black.opacity(0.45), radius: 1.5, y: 0.5)
                .foregroundStyle(.primary.opacity(hovering && isTimed ? min(1, emphasis + 0.25) : emphasis))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .scaleEffect(isCurrent ? 1 : 0.94, anchor: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isTimed)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.35), value: isCurrent)
        .animation(.smooth(duration: 0.2), value: hovering)
    }
}

private struct QueueView: View {
    let items: [QueueItem]
    let note: String?
    let height: CGFloat
    let onPlay: (QueueItem) -> Void

    var body: some View {
        if items.isEmpty {
            Text(note ?? String(localized: "Loading…")).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: height)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(items) { item in
                        Button { onPlay(item) } label: {
                            QueueRow(item: item)
                        }
                        .buttonStyle(.plain)
                        .help("Play this track")
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            .frame(height: height)
        }
    }
}


/// Lyrics or Up Next. Built from plain buttons: the system's segmented control did not take clicks inside the glass.
private struct PaneSwitch: View {
    let service: NowPlayingService

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PlayerPane.allCases) { pane in
                Button { service.pane = pane } label: {
                    Text(pane.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(service.pane == pane ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background { if service.pane == pane { Capsule().fill(.white.opacity(0.2)) } }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.black.opacity(0.18), in: .capsule)
    }
}


private struct QueueRow: View {
    let item: QueueItem
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text(item.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.white.opacity(hovering ? 0.12 : 0), in: .rect(cornerRadius: 10, style: .continuous))
        .contentShape(.rect)
        .scaleEffect(hovering ? 1.03 : 1, anchor: .leading)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.16), value: hovering)
    }
}


/// Takes the mouse. A drag moves the whole window (when it is allowed to), and a press that never moved counts as a click.
/// It follows the pointer itself instead of leaving it to the window's own dragging, which does not work in this kind of panel.
private struct GripView: NSViewRepresentable {
    var movesWindow: Bool
    var onRelease: (CGVector) -> Void = { _ in }
    var onDragState: (Bool) -> Void = { _ in }
    var onHover: (Bool) -> Void = { _ in }
    var onClick: () -> Void

    func makeNSView(context: Context) -> NSView { Grip() }

    func updateNSView(_ view: NSView, context: Context) {
        guard let grip = view as? Grip else { return }
        grip.movesWindow = movesWindow
        grip.onRelease = onRelease
        grip.onDragState = onDragState
        grip.onHover = onHover
        grip.onClick = onClick
    }

    private final class Grip: NSView {
        var movesWindow = true
        var onClick: () -> Void = {}
        var onRelease: (CGVector) -> Void = { _ in }
        var onDragState: (Bool) -> Void = { _ in }
        var onHover: (Bool) -> Void = { _ in }
        private var startMouse = NSPoint.zero
        private var startOrigin = NSPoint.zero
        private var moved = false
        private var lastMouse = NSPoint.zero
        private var lastTime: TimeInterval = 0
        private var velocity = CGVector.zero

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
        }

        override func mouseEntered(with event: NSEvent) { onHover(true) }
        override func mouseExited(with event: NSEvent) { onHover(false) }
        override func resetCursorRects() { if movesWindow { addCursorRect(bounds, cursor: .openHand) } }

        override func mouseDown(with event: NSEvent) {
            startMouse = window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
            startOrigin = window?.frame.origin ?? .zero
            moved = false
            lastMouse = NSEvent.mouseLocation
            lastTime = event.timestamp
            velocity = .zero
        }

        override func mouseDragged(with event: NSEvent) {
            guard movesWindow, let window else { return }
            let now = window.convertPoint(toScreen: event.locationInWindow)
            let dx = now.x - startMouse.x, dy = now.y - startMouse.y
            if !moved, hypot(dx, dy) < 3 { return }
            if !moved { onDragState(true) }
            moved = true
            // The pointer's speed, smoothed, for throwing the window on when it is let go.
            let mouse = NSEvent.mouseLocation
            let elapsed = event.timestamp - lastTime
            if elapsed > 0.001 {
                velocity = CGVector(dx: velocity.dx * 0.5 + (mouse.x - lastMouse.x) / elapsed * 0.5,
                                    dy: velocity.dy * 0.5 + (mouse.y - lastMouse.y) / elapsed * 0.5)
                lastMouse = mouse
                lastTime = event.timestamp
            }
            window.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
        }

        override func mouseUp(with event: NSEvent) {
            if moved {
                // Held still before letting go: nothing to throw.
                onRelease(event.timestamp - lastTime > 0.1 ? .zero : velocity)
                onDragState(false)
            } else { onClick() }
        }
    }
}
