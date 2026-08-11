// Фон окна DMG: подпись и стрелка от приложения к «Программам».
//
// Рисуется кодом по тем же причинам, что и иконка: нужен @2x, а масштабировать
// готовую картинку — значит получить мыло на retina.
//
// Координаты здесь — как у Finder: начало в левом верхнем углу окна. CoreGraphics
// считает снизу, поэтому по вертикали всё переворачивается один раз, в flip().

import AppKit

/// Размер окна DMG в точках. Иконки расставляются в этих же координатах,
/// поэтому числа держим рядом — разъедутся, и стрелка будет мимо.
let windowSize = CGSize(width: 640, height: 400)
let appIconCenter = CGPoint(x: 170, y: 190)
let applicationsCenter = CGPoint(x: 470, y: 190)

func flip(_ y: CGFloat) -> CGFloat { windowSize.height - y }

func drawBackground(scale: CGFloat, in ctx: CGContext) {
    ctx.scaleBy(x: scale, y: scale)
    ctx.setShouldAntialias(true)

    // Тот же графит с синевой, что у иконки: окно должно выглядеть
    // продолжением приложения, а не случайной картинкой.
    let colors = [
        NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.23, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.13, alpha: 1).cgColor
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: windowSize.height),
                           end: CGPoint(x: 0, y: 0),
                           options: [])

    // Стрелка между иконками. Начинается и кончается с отступом: под иконками
    // ещё подписи, и упираться в них не надо.
    let inset: CGFloat = 78
    let startX = appIconCenter.x + inset
    let endX = applicationsCenter.x - inset
    let y = flip(appIconCenter.y)

    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.34).cgColor)
    ctx.setLineWidth(3)
    ctx.setLineCap(.round)
    ctx.move(to: CGPoint(x: startX, y: y))
    ctx.addLine(to: CGPoint(x: endX - 10, y: y))
    ctx.strokePath()

    // Наконечник
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.34).cgColor)
    ctx.move(to: CGPoint(x: endX + 6, y: y))
    ctx.addLine(to: CGPoint(x: endX - 14, y: y + 11))
    ctx.addLine(to: CGPoint(x: endX - 14, y: y - 11))
    ctx.closePath()
    ctx.fillPath()

    // Подписи
    func draw(_ text: String, size: CGFloat, weight: NSFont.Weight,
              alpha: CGFloat, atY finderY: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor.white.withAlphaComponent(alpha)
        ]
        let line = NSAttributedString(string: text, attributes: attributes)
        let bounds = line.size()
        let origin = CGPoint(x: (windowSize.width - bounds.width) / 2,
                             y: flip(finderY) - bounds.height / 2)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        line.draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()
    }

    draw("AudioMixer", size: 22, weight: .semibold, alpha: 0.92, atY: 56)
    draw("Перетащите в «Программы»", size: 13, weight: .regular, alpha: 0.55, atY: 84)
    // Формулировка проверена: способ «правая кнопка → Открыть» в свежих
    // macOS больше не работает, приложение без Developer ID открывается
    // только через настройки.
    // Ниже ~360 текст уходит под панель пути Finder, если она включена
    // у пользователя. Нижние строки держим выше этой границы.
    draw("Не открывается? Настройки → Конфиденциальность и безопасность → «Открыть всё равно»",
         size: 11, weight: .regular, alpha: 0.34, atY: 302)
    draw("Требуется macOS 14.4 или новее",
         size: 11, weight: .regular, alpha: 0.24, atY: 326)
}

func render(scale: CGFloat, to path: String) {
    let pixels = CGSize(width: windowSize.width * scale, height: windowSize.height * scale)
    guard let ctx = CGContext(data: nil, width: Int(pixels.width), height: Int(pixels.height),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    drawBackground(scale: scale, in: ctx)
    guard let image = ctx.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
render(scale: 1, to: "\(outputDir)/dmg-background.png")
render(scale: 2, to: "\(outputDir)/dmg-background@2x.png")
print("готово: dmg-background.png и @2x в \(outputDir)")
