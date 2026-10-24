import CoreText
import SwiftUI
import UIKit

/// Шрифт Aerial — Commissioner, как в приложении для ТВ (`ui/theme` ТВ, файл тот же: `Resources/Fonts`, лицензия OFL).
/// Файл переменный (оси насыщенности `wght` 100–900 и наклона `slnt`), по умолчанию — самый тонкий, поэтому
/// насыщенность ставится явно осью. Размеры — по стилям текста iOS (учитывают размер текста в настройках системы).
enum AerialFont {
    /// PostScript-имя после регистрации файла; nil — файла нет, тогда системный шрифт.
    private static let name: String? = {
        guard let url = Bundle.main.url(forResource: "Commissioner", withExtension: "ttf") else { return nil }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        guard let provider = CGDataProvider(url: url as CFURL), let font = CGFont(provider) else { return nil }
        return font.postScriptName as String?
    }()

    private static let weights: [Font.Weight: CGFloat] = [
        .ultraLight: 200, .thin: 100, .light: 300, .regular: 400, .medium: 500,
        .semibold: 600, .bold: 700, .heavy: 800, .black: 900,
    ]

    private static let styles: [Font.TextStyle: UIFont.TextStyle] = [
        .largeTitle: .largeTitle, .title: .title1, .title2: .title2, .title3: .title3, .headline: .headline,
        .subheadline: .subheadline, .body: .body, .callout: .callout, .footnote: .footnote,
        .caption: .caption1, .caption2: .caption2,
    ]

    /// Насыщенность стиля по умолчанию, как у системного: `headline` — полужирный, `largeTitle`… — обычный.
    static func defaultWeight(_ style: Font.TextStyle) -> Font.Weight { style == .headline ? .semibold : .regular }

    static func uiFont(size: CGFloat, weight: Font.Weight, italic: Bool = false) -> UIFont {
        guard let name, let base = UIFont(name: name, size: size) else {
            return .systemFont(ofSize: size, weight: weight == .bold ? .bold : weight == .semibold ? .semibold : .regular)
        }
        // Ось задаётся числовым тегом: 'wght', 'slnt'.
        var axes: [Int: CGFloat] = [0x7767_6874: weights[weight] ?? 400]
        if italic { axes[0x736C_6E74] = -10 }
        let descriptor = base.fontDescriptor.addingAttributes([
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): axes,
        ])
        return UIFont(descriptor: descriptor, size: size)
    }

    static func size(_ style: Font.TextStyle) -> CGFloat {
        UIFont.preferredFont(forTextStyle: styles[style] ?? .body).pointSize
    }

    /// Заголовки панелей навигации — тем же шрифтом.
    static func applyToNavigationBars() {
        let appearance = UINavigationBar.appearance()
        appearance.titleTextAttributes = [.font: uiFont(size: 17, weight: .semibold)]
        appearance.largeTitleTextAttributes = [.font: uiFont(size: 34, weight: .bold)]
    }
}

extension Font {
    /// Commissioner стилем текста iOS: `.aerial(.headline)`, `.aerial(.subheadline, .semibold)`.
    static func aerial(_ style: Font.TextStyle, _ weight: Font.Weight? = nil) -> Font {
        Font(AerialFont.uiFont(size: AerialFont.size(style), weight: weight ?? AerialFont.defaultWeight(style)))
    }

    /// Commissioner заданного размера — вместо `.system(size:weight:)`.
    static func aerial(size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        Font(AerialFont.uiFont(size: size, weight: weight))
    }

    /// Курсив — наклоном шрифта (у Commissioner нет отдельного курсива).
    static func aerialItalic(_ style: Font.TextStyle) -> Font {
        Font(AerialFont.uiFont(size: AerialFont.size(style), weight: AerialFont.defaultWeight(style), italic: true))
    }
}
