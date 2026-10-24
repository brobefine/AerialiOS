import SwiftUI
import UIKit

/// Цвета Aerial: волны знака (#7FDCFF, #3E7BEA) — акцент; фон — почти чёрный, как у подложки знака.
enum Theme {
    static let accent = Color(hex: 0x7FDCFF)
    static let accentDeep = Color(hex: 0x3E7BEA)
    static let background = Color(hex: 0x0A0B0D)
    static let card = Color(hex: 0x1A1C21)
    static let secondaryText = Color.white.opacity(0.62)

    /// Ширина постера в рядах: телефон — 116 pt, планшет — 150 pt.
    static func posterWidth(_ size: UserInterfaceSizeClass?) -> CGFloat { size == .regular ? 150 : 116 }
    static func landscapeWidth(_ size: UserInterfaceSizeClass?) -> CGFloat { size == .regular ? 340 : 260 }

    /// Цвет кольца оценки, как `ratingColor` ТВ: от 70 % — зелёный, от 50 % — жёлтый, ниже — красный.
    static func rating(_ share: Double) -> Color {
        share >= 0.7 ? Color(hex: 0x3DDC84) : share >= 0.5 ? Color(hex: 0xFFC83D) : Color(hex: 0xFF5A4E)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

extension View {
    /// Стекло iOS 26 (Liquid Glass); на iOS 18 — материал.
    @ViewBuilder
    func glass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(interactive ? Glass.regular.interactive() : Glass.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

extension View {
    /// Экран с картинкой под панелью навигации. На iOS 26 панель и так прозрачная, а при прокрутке система сама
    /// размывает край под ней — её не трогаем; на iOS 18 прячем фон панели.
    @ViewBuilder
    func clearNavigationBar() -> some View {
        if #available(iOS 26, *) {
            self
        } else {
            self.toolbarBackground(.hidden, for: .navigationBar)
        }
    }
}

/// Главная кнопка, как «Смотреть» у Apple TV: белая капсула с чёрным текстом.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(.black)
            .padding(.horizontal, 22)
            .frame(height: 48)
            .frame(maxWidth: .infinity)
            .background(.white, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Круглая кнопка на стекле: «Мой список», трейлер, закрыть.
struct CircleGlassButtonStyle: ButtonStyle {
    var size: CGFloat = 48

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            // Интерактивное стекло внутри стиля кнопки на iOS 26 перехватывало касание — кнопка не срабатывала.
            .glass(in: Circle())
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// Плашка-тег: «4K», «HDR», «WEB-DL».
struct TagLabel: View {
    let text: String
    var highlighted = false

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(highlighted ? .black : .white.opacity(0.85))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(highlighted ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.white.opacity(0.12)),
                        in: RoundedRectangle(cornerRadius: 5))
    }
}
