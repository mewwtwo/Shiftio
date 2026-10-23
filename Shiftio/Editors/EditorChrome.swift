import SwiftUI

/// Shared look of the editor windows: tinted glass, close button on the left, centred title, footer buttons.
struct EditorChrome<Content: View, Footer: View>: View {
    let title: LocalizedStringKey
    let tint: Color
    let onClose: () -> Void
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            footer
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
        }
        // Blur and opacity come from macOS: Liquid Glass style, Reduce Transparency, Increase Contrast.
        .background { shape.fill(.clear).adaptiveGlass(tint: tint, tintAmount: 1, large: true, in: shape) }
        .overlay { shape.stroke(.white.opacity(0.16), lineWidth: 0.7).allowsHitTesting(false) }
        .clipShape(shape)
        // Buttons on the glass stay neutral. The accent is passed on by hand to what can be changed (pills, sliders, switches, Save).
        .tint(Color(white: 0.55))
        .background {
            // ⌘W like any window.
            Button("Close", action: onClose).keyboardShortcut("w").opacity(0).accessibilityHidden(true)
        }
    }

    private var header: some View {
        ZStack {
            WindowDragArea()
            Text(title).font(.headline)
            HStack {
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)) }
                    .buttonStyle(.glass)
                    // Window controls stay neutral; the accent is for what can be changed.
                    .tint(Color(white: 0.55))
                    .buttonBorderShape(.circle)
                    .keyboardShortcut(.cancelAction)
                    .help("Close (esc)")
                Spacer()
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 52)
    }
}

struct PillPicker<Value: Hashable>: View {
    let items: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    let tint: Color
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.self) { item in
                let isSelected = item == selection
                Button { withAnimation(.smooth(duration: 0.22)) { selection = item } } label: {
                    Text(title(item))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background { if isSelected { Capsule().fill(tint).matchedGeometryEffect(id: "pill", in: namespace) } }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.black.opacity(0.08), in: .capsule)
    }
}
