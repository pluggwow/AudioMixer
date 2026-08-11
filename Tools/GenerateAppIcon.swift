// Иконка AudioMixer: три вертикальных фейдера на скруглённом квадрате.
//
// Рисуется кодом, а не в редакторе: один источник, из которого выходят все
// размеры без ручного масштабирования и замыливания.

import AppKit

// MARK: - Форма

/// Скруглённый квадрат в стиле macOS. Не обычное скругление, а суперэллипс:
/// у системных иконок углы «перетекают» в стороны, и обычная дуга рядом с
/// ними выглядит инородно.
func squirclePath(in rect: CGRect, exponent: CGFloat = 5.4) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 512

    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * pow(abs(ct), 2 / exponent) * (ct < 0 ? -1 : 1)
        let y = cy + b * pow(abs(st), 2 / exponent) * (st < 0 ? -1 : 1)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

// MARK: - Рисование

func drawIcon(size: CGFloat, in ctx: CGContext) {
    let s = size / 1024  // всё считаем в тысячных долях канвы

    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Поле иконки: по сетке macOS содержимое занимает 824 из 1024,
    // остальное — воздух, за счёт которого иконки в Dock одного размера.
    let plate = CGRect(x: 100 * s, y: 110 * s, width: 824 * s, height: 824 * s)
    let shape = squirclePath(in: plate)

    // Тень под плашкой — как у системных иконок, чуть ниже центра.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s),
                  blur: 28 * s,
                  color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.addPath(shape)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Подложка: тёмный графит с лёгким градиентом сверху вниз.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // Графит с синевой, а не нейтральный: чисто серая иконка в Dock выглядит
    // системной утилитой, а синий отсылает к звуку и к акценту в самой панели.
    let colors = [
        NSColor(calibratedRed: 0.23, green: 0.25, blue: 0.33, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.13, alpha: 1).cgColor
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: plate.midX, y: plate.maxY),
                           end: CGPoint(x: plate.midX, y: plate.minY),
                           options: [])

    // Блик по верхнему краю — тонкая светлая полоса, «стекло».
    let glossColors = [
        NSColor.white.withAlphaComponent(0.16).cgColor,
        NSColor.white.withAlphaComponent(0.0).cgColor
    ] as CFArray
    let gloss = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: glossColors, locations: [0, 1])!
    ctx.drawLinearGradient(gloss,
                           start: CGPoint(x: plate.midX, y: plate.maxY),
                           end: CGPoint(x: plate.midX, y: plate.maxY - 300 * s),
                           options: [])
    ctx.restoreGState()

    // Фейдеры: три вертикальных дорожки с ручками на разной высоте.
    // Разная высота — не украшение: именно она читается как «микшер»,
    // а не как «три палки».
    let levels: [CGFloat] = [0.72, 0.30, 0.90]
    let trackWidth = 46 * s
    let trackHeight = 470 * s
    let knobSize = 104 * s
    let spacing = 170 * s

    let centerY = plate.midY
    let firstX = plate.midX - spacing

    for (index, level) in levels.enumerated() {
        let x = firstX + CGFloat(index) * spacing
        let track = CGRect(x: x - trackWidth / 2,
                           y: centerY - trackHeight / 2,
                           width: trackWidth,
                           height: trackHeight)

        // Дорожка
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.16).cgColor)
        ctx.addPath(CGPath(roundedRect: track,
                           cornerWidth: trackWidth / 2, cornerHeight: trackWidth / 2,
                           transform: nil))
        ctx.fillPath()

        // Заполнение снизу до ручки. Ход ручки короче дорожки на её диаметр —
        // тем же правилом живёт слайдер в самой панели, иначе ручка вылезает
        // за скруглённый конец.
        let travel = track.height - knobSize
        let knobY = track.minY + knobSize / 2 + travel * level
        let fill = CGRect(x: track.minX, y: track.minY,
                          width: track.width, height: knobY - track.minY)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.85).cgColor)
        ctx.addPath(CGPath(roundedRect: fill,
                           cornerWidth: trackWidth / 2, cornerHeight: trackWidth / 2,
                           transform: nil))
        ctx.fillPath()

        // Ручка
        let knob = CGRect(x: x - knobSize / 2, y: knobY - knobSize / 2,
                          width: knobSize, height: knobSize)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -4 * s),
                      blur: 12 * s,
                      color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: knob)
        ctx.restoreGState()
    }
}

// MARK: - Вывод

func render(size: CGFloat, to path: String) {
    let pixels = Int(size)
    guard let ctx = CGContext(data: nil, width: pixels, height: pixels,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    drawIcon(size: size, in: ctx)
    guard let image = ctx.makeImage() else { return }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

// MARK: - Набор для Assets.xcassets

/// Размеры, которые требует macOS: пять базовых по два масштаба.
let variants: [(base: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2)
]

let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources/Assets.xcassets/AppIcon.appiconset"

var images: [String] = []
for variant in variants {
    let pixels = variant.base * variant.scale
    let suffix = variant.scale == 1 ? "" : "@\(variant.scale)x"
    let file = "icon_\(variant.base)x\(variant.base)\(suffix).png"
    render(size: CGFloat(pixels), to: "\(outputDir)/\(file)")
    images.append("""
        {
          "size" : "\(variant.base)x\(variant.base)",
          "idiom" : "mac",
          "filename" : "\(file)",
          "scale" : "\(variant.scale)x"
        }
    """)
}

let contents = """
{
  "images" : [
\(images.joined(separator: ",\n"))
  ],
  "info" : { "version" : 1, "author" : "xcode" }
}
"""
try? contents.write(toFile: "\(outputDir)/Contents.json", atomically: true, encoding: .utf8)
print("готово: \(variants.count) размеров и Contents.json в \(outputDir)")
