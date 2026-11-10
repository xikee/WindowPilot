import SwiftUI

enum Palette {
    static let background = Color(hex: 0x101113)
    static let sidebar = Color(hex: 0x151618)
    static let surface = Color(hex: 0x1B1C1F)
    static let raised = Color(hex: 0x242528)
    static let border = Color.white.opacity(0.08)
    static let text = Color(hex: 0xF3F1ED)
    static let secondary = Color(hex: 0x96979D)
    static let accent = Color(hex: 0xD6F28A)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}

struct BrandMark: View {
    var size: CGFloat = 38
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29).fill(Palette.accent)
            Image(systemName: "rectangle.on.rectangle.angled").font(.system(size: size * 0.48, weight: .semibold)).foregroundStyle(Palette.background)
        }.frame(width: size, height: size)
    }
}

struct KeyCap: View {
    let text: String
    var large = false
    var body: some View {
        Text(text).font(.system(size: large ? 24 : 11, weight: .medium, design: .rounded))
            .foregroundStyle(Palette.text).padding(.horizontal, large ? 18 : 7).padding(.vertical, large ? 12 : 4)
            .background(RoundedRectangle(cornerRadius: large ? 11 : 5).fill(Color.white.opacity(0.055)))
            .overlay(RoundedRectangle(cornerRadius: large ? 11 : 5).stroke(Color.white.opacity(0.1), lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 0, y: large ? 3 : 1)
    }
}

struct AccentButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold)).padding(.horizontal, 16).padding(.vertical, 11)
            .foregroundStyle(Palette.background).background(Palette.accent.opacity(configuration.isPressed ? 0.75 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).padding(.horizontal, 13).padding(.vertical, 9)
            .foregroundStyle(Palette.text).background(Color.white.opacity(configuration.isPressed ? 0.1 : 0.04))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.border))
    }
}
