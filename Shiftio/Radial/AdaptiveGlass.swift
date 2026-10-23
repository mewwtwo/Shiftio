import AppKit
import SwiftUI

struct GlassSettings: Equatable {
    var style = GlassStyle.clear
    var frost = 0.5
    var tint = 0.1
}

extension EnvironmentValues {
    @Entry var glassSettings = GlassSettings()
}

/// Glass surface with a user-selectable look. "Follow macOS" leaves it to the system (Clear/Tinted setting),
/// Reduce Transparency always wins with a solid fill, and Increase Contrast adds an outline.
struct AdaptiveGlass<S: Shape>: ViewModifier {
    var tint: Color?
    /// Weight of this surface's tint relative to the global tint setting (1 = subtle, higher = stronger).
    var tintAmount = 1.0
    var interactive = false
    /// A thin, always-clear sheet used under other glass so it doesn't add frost.
    var lens = false
    /// Big surfaces that hold text and controls (editor windows) get a frosted base under the glass, so what
    /// is behind the window can't show through the labels.
    var large = false
    let shape: S

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.glassSettings) private var settings

    /// `-ShiftioForceSolid` simulates Reduce Transparency for screenshots and testing.
    private var forceSolid: Bool { reduceTransparency || ProcessInfo.processInfo.arguments.contains("-ShiftioForceSolid") }

    private var effectiveTint: Color? {
        tint.map { $0.opacity(min(1, settings.tint * tintAmount)) }
    }

    /// Bright edge that catches the light, which is what makes glass read as glass rather than a gray plate.
    private var rim: some View {
        shape
            .stroke(LinearGradient(colors: [.white.opacity(0.7), .white.opacity(0.06), .white.opacity(0.32)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        switch forceSolid ? GlassStyle.solid : settings.style {
        case .solid:
            content
                .background {
                    shape.fill(Color(nsColor: .controlBackgroundColor))
                    if let tint { shape.fill(tint.opacity(min(1, settings.tint * tintAmount * 2))) }
                }
                .overlay { shape.stroke(.primary.opacity(0.25), lineWidth: 1) }
        case .frosted:
            content
                .background {
                    shape.fill(Self.material(for: settings.frost))
                    if let effectiveTint { shape.fill(effectiveTint) }
                }
                .overlay { shape.stroke(.white.opacity(contrast == .increased ? 0.5 : 0.18), lineWidth: 0.6) }
        case .clear where lens, .system where lens:
            // Real glass already refracts what's behind it; a backing disc would only darken the hole.
            content
        case .clear where large, .system where large:
            content
                // Like the Quick Look window: a smooth, strong blur of what is behind it. Liquid Glass is meant for small controls; across a
                // whole window its edge lensing showed up as smudges and clipped blobs along the borders, so large surfaces use a material.
                .background {
                    // An AppKit blur that stays active whether or not the window has the keys (SwiftUI materials turn flat and opaque
                    // in a window without them).
                    BackdropBlur().clipShape(shape)
                    shape.fill(.black.opacity(colorScheme == .dark ? 0.04 : 0))
                }
                .overlay { shape.stroke(.white.opacity(contrast == .increased ? 0.5 : 0.18), lineWidth: 0.6) }
        case .clear:
            content
                // Clear glass needs a dimming layer behind it, or light wallpapers wash out the labels. In the light appearance
                // the layer is pearl white instead of dark, so the petals read as light glass with dark labels.
                .background { shape.fill(colorScheme == .dark ? Color.black.opacity(0.14 + settings.tint * 0.5) : Color.white.opacity(0.42 + settings.tint * 0.3)) }
                .glassEffect(Self.glass(.clear, tint: effectiveTint, interactive: interactive), in: shape)
                .overlay { rim }
                .overlay { if contrast == .increased { shape.stroke(.primary.opacity(0.5), lineWidth: 1) } }
        case .system:
            content
                .glassEffect(Self.glass(.regular, tint: effectiveTint, interactive: interactive), in: shape)
                .overlay { rim.opacity(0.6) }
                .overlay { if contrast == .increased { shape.stroke(.primary.opacity(0.5), lineWidth: 1) } }
        }
    }

    private static func glass(_ base: Glass, tint: Color?, interactive: Bool) -> Glass {
        var glass = base
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }

    /// The system offers blur in fixed steps, so the Blur slider picks one.
    static func material(for frost: Double) -> Material {
        switch frost {
        case ..<0.2: .ultraThinMaterial
        case ..<0.4: .thinMaterial
        case ..<0.6: .regularMaterial
        case ..<0.8: .thickMaterial
        default: .ultraThickMaterial
        }
    }
}

extension View {
    func adaptiveGlass<S: Shape>(tint: Color? = nil, tintAmount: Double = 1, interactive: Bool = false,
                                 lens: Bool = false, large: Bool = false, in shape: S) -> some View {
        modifier(AdaptiveGlass(tint: tint, tintAmount: tintAmount, interactive: interactive, lens: lens,
                               large: large, shape: shape))
    }
}


/// The behind-window blur of a HUD, always in its active (translucent) state. Like the Quick Look window it is a dark HUD in
/// the dark appearance and a bright, white-ish frosted sheet in the light one.
struct BackdropBlur: NSViewRepresentable {
    private final class BlurView: NSVisualEffectView {
        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            material = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua ? .popover : .hudWindow
        }
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = BlurView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
