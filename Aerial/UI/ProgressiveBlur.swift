import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Прогрессивное размытие (как `VodFrost.progressive` ТВ и ПК): картинка и под ней её зеркальная копия — одна полоса,
/// размытая системным переменным размытием (`CIMaskedVariableBlur`): фокус теряется с `from` высоты картинки над краем,
/// полное размытие — на `to` ниже края. Склеенная полоса размывается целиком — на стыке нет «складки». Отдельного
/// затемнения нет: яркость размытой части опускается до `lumaCap` (светлое приглушается, тёмное не трогается).
/// Считается один раз на картинку и размер, в фоне; результат — в кэше.
enum ProgressiveBlur {
    static let from: CGFloat = 0.35
    static let to: CGFloat = 0.03
    /// Потолок яркости размытого продолжения — как `MIRROR_LUMA_CAP` ТВ (105 из 255).
    static let lumaCap: CGFloat = 105 / 255
    /// Радиус полного размытия, pt (около 36 px на ТВ).
    static let radius: CGFloat = 18

    private static let cache = NSCache<NSString, UIImage>()
    private static let context = CIContext()

    static func key(_ path: String, _ width: CGFloat, _ height: CGFloat) -> NSString {
        "\(path)|\(Int(width))|\(Int(height))" as NSString
    }

    static func cached(_ key: NSString) -> UIImage? { cache.object(forKey: key) }

    /// Полоса `width`×`height * 2` pt: картинка (заполнением, по центру) и её размытое продолжение. `mirror == false` —
    /// только сама картинка `width`×`height` с размытым низом (постеры со сведениями, как `progressiveBand` ТВ).
    static func make(_ image: UIImage, width: CGFloat, height: CGFloat, scale: CGFloat, key: NSString, mirror: Bool = true) -> UIImage? {
        if let hit = cache.object(forKey: key) { return hit }
        let w = (width * scale).rounded(), h = (height * scale).rounded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let total = mirror ? h * 2 : h
        let strip = UIGraphicsImageRenderer(size: CGSize(width: w, height: total), format: format).image { ctx in
            let fill = max(w / image.size.width, h / image.size.height)
            let size = CGSize(width: image.size.width * fill, height: image.size.height * fill)
            let rect = CGRect(x: (w - size.width) / 2, y: (h - size.height) / 2, width: size.width, height: size.height)
            ctx.cgContext.saveGState()
            ctx.cgContext.clip(to: CGRect(x: 0, y: 0, width: w, height: h))
            image.draw(in: rect)
            ctx.cgContext.restoreGState()
            guard mirror else { return }
            ctx.cgContext.saveGState()
            ctx.cgContext.clip(to: CGRect(x: 0, y: h, width: w, height: h))
            ctx.cgContext.translateBy(x: 0, y: h * 2)
            ctx.cgContext.scaleBy(x: 1, y: -1)
            image.draw(in: rect)
            ctx.cgContext.restoreGState()
        }
        guard let input = CIImage(image: strip) else { return nil }
        let extent = input.extent
        // Маска: 0 — чётко, 1 — полное размытие. Core Image считает y снизу.
        let gradient = CIFilter.linearGradient()
        gradient.point0 = CGPoint(x: 0, y: total - h * (1 - from))
        gradient.point1 = CGPoint(x: 0, y: total - h * (1 + to))
        gradient.color0 = CIColor(red: 0, green: 0, blue: 0)
        gradient.color1 = CIColor(red: 1, green: 1, blue: 1)
        let mask = gradient.outputImage?.cropped(to: extent)
        let blur = CIFilter.maskedVariableBlur()
        blur.inputImage = input.clampedToExtent()
        blur.mask = mask
        blur.radius = Float(radius * scale)
        guard var output = blur.outputImage?.cropped(to: extent) else { return nil }
        // Яркость размытой части: средняя ниже края выше потолка — приглушить её по той же маске.
        let below = mirror ? CGRect(x: 0, y: 0, width: w, height: h * (1 - to)) : CGRect(x: 0, y: 0, width: w, height: h * from)
        let average = CIFilter.areaAverage()
        average.inputImage = output
        average.extent = below
        var pixel = [UInt8](repeating: 0, count: 4)
        if let avg = average.outputImage {
            context.render(avg, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            let luma = (0.299 * CGFloat(pixel[0]) + 0.587 * CGFloat(pixel[1]) + 0.114 * CGFloat(pixel[2])) / 255
            if luma > lumaCap, let mask {
                let f = lumaCap / luma
                let dim = CIFilter.colorMatrix()
                dim.inputImage = output
                dim.rVector = CIVector(x: f, y: 0, z: 0, w: 0)
                dim.gVector = CIVector(x: 0, y: f, z: 0, w: 0)
                dim.bVector = CIVector(x: 0, y: 0, z: f, w: 0)
                let blend = CIFilter.blendWithMask()
                blend.inputImage = dim.outputImage
                blend.backgroundImage = output
                blend.maskImage = mask
                if let blended = blend.outputImage?.cropped(to: extent) { output = blended }
            }
        }
        guard let cg = context.createCGImage(output, from: extent) else { return nil }
        let result = UIImage(cgImage: cg, scale: scale, orientation: .up)
        cache.setObject(result, forKey: key)
        return result
    }
}
