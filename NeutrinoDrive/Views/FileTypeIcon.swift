import SwiftUI

// MARK: - FileTypeIcon

/// The tinted, rounded tile that stands in for a file or folder throughout the app.
///
/// Draws the custom Neutrino artwork for the native editor formats and an SF Symbol for
/// everything else, so callers never have to know which of the two a given item needs.
struct FileTypeIcon: View {

    let kind: FileKind

    /// Edge length of the tile. The glyph scales with it, so a grid or a compact row can ask
    /// for a different size without the proportions drifting.
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2, style: .continuous)
                .fill(kind.tint.opacity(0.15))
                .frame(width: size, height: size)
            glyph
                .foregroundStyle(kind.tint)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var glyph: some View {
        if let assetName = kind.assetName {
            Image(assetName)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.55, height: size * 0.55)
        } else {
            Image(systemName: kind.symbolName)
                .font(.system(size: size * 0.45, weight: .medium))
        }
    }
}

// MARK: - Tint

extension FileKind {

    /// The colour that identifies this type at a glance.
    ///
    /// Hues match the web client's `getIconColor` so a Doc is the same blue on both, but each
    /// carries a lighter dark-mode variant: the web's values are tuned against a white page
    /// and several of them (the 600-weight green and cyan especially) fail contrast on a dark
    /// one.
    var tint: Color {
        switch self {
        case .folder:          return Self.adaptive(light: 0x2563EB, dark: 0x60A5FA)
        case .neutrinoDoc:     return Self.adaptive(light: 0x2563EB, dark: 0x60A5FA)
        case .neutrinoSheet:   return Self.adaptive(light: 0x16A34A, dark: 0x4ADE80)
        case .neutrinoSlide:   return Self.adaptive(light: 0xEA580C, dark: 0xFB923C)
        case .neutrinoDiagram: return Self.adaptive(light: 0x0891B2, dark: 0x22D3EE)
        case .neutrinoDrawing: return Self.adaptive(light: 0x65A30D, dark: 0xA3E635)
        case .neutrinoNote:    return Self.adaptive(light: 0xD97706, dark: 0xFBBF24)
        case .image:           return Self.adaptive(light: 0x7C3AED, dark: 0xA78BFA)
        case .video:           return Self.adaptive(light: 0xE11D48, dark: 0xFB7185)
        case .audio:           return Self.adaptive(light: 0xD97706, dark: 0xFBBF24)
        case .pdf:             return Self.adaptive(light: 0xE11D48, dark: 0xFB7185)
        case .spreadsheet:     return Self.adaptive(light: 0x16A34A, dark: 0x4ADE80)
        case .presentation:    return Self.adaptive(light: 0xEA580C, dark: 0xFB923C)
        case .document:        return Self.adaptive(light: 0x2563EB, dark: 0x60A5FA)
        case .code:            return Self.adaptive(light: 0x0891B2, dark: 0x22D3EE)
        case .json:            return Self.adaptive(light: 0x0D9488, dark: 0x2DD4BF)
        case .archive:         return Self.adaptive(light: 0xEA580C, dark: 0xFB923C)
        case .text:            return Self.adaptive(light: 0x475569, dark: 0x94A3B8)
        case .unknown:         return Self.adaptive(light: 0x64748B, dark: 0x94A3B8)
        }
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red:   CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue:  CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Preview

#Preview("File type icons") {
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90))], spacing: 20) {
            ForEach(FileKind.allCases, id: \.self) { kind in
                VStack(spacing: 6) {
                    FileTypeIcon(kind: kind)
                    Text(kind.accessibilityDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }
}
