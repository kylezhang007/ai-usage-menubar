import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Two-stop diagonal gradient, the building block of every ring, number and pill.
struct Shade {
    var from: UInt32
    var to: UInt32

    var gradient: LinearGradient {
        LinearGradient(colors: [Color(hex: from), Color(hex: to)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var track: Color { Color(hex: to, opacity: 0.2) }
}

/// One color family per section: Claude orange, Codex green, API blue.
struct SectionTheme {
    var shades: [Shade]              // deep → light
    var plan: LinearGradient         // plan label text
    var tint: (UInt32, Double, UInt32, Double)

    /// A light wash of the section color inside its glass tile.
    var glassTint: Color { Color(hex: tint.2, opacity: 0.22) }
    func shade(_ i: Int) -> Shade { shades[min(i, shades.count - 1)] }

    static let claude = SectionTheme(
        shades: [Shade(from: 0xFF7A30, to: 0xE2410B),
                 Shade(from: 0xFFA04A, to: 0xF7731C),
                 Shade(from: 0xFFD27A, to: 0xFFA92E)],
        plan: Shade(from: 0xFF7A30, to: 0xE2410B).gradient,
        tint: (0xFFCE8C, 0.32, 0xFF966E, 0.14))

    static let codex = SectionTheme(
        shades: [Shade(from: 0x8EDB5A, to: 0x1FAE6E),
                 Shade(from: 0x4FD9A6, to: 0x0E9F76)],
        plan: LinearGradient(colors: [Color(hex: 0x4CC560), Color(hex: 0x38BA67), Color(hex: 0x1FAE6E)],
                             startPoint: .leading, endPoint: .trailing),
        tint: (0xBEF096, 0.32, 0x50D296, 0.14))

    static let api = SectionTheme(
        shades: [Shade(from: 0x4FC3FF, to: 0x3B6CFF),
                 Shade(from: 0x6CC8F5, to: 0x2F80ED),
                 Shade(from: 0x3FD3E8, to: 0x3B82F6)],
        plan: Shade(from: 0x4FC3FF, to: 0x3B6CFF).gradient,
        tint: (0x96D7FF, 0.32, 0x648CFF, 0.14))
}
