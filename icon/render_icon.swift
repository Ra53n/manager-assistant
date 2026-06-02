import AppKit

// Рендерит иконку приложения 1024×1024 в PNG.
// Дизайн: фиолетово-синий «squircle» (как у нативных macOS-иконок) с белым
// чат-«пузырём» и тремя точками внутри.

let size = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("no rep") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

let s = CGFloat(size)
ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

// Фон-squircle с отступом от краёв.
let margin: CGFloat = 88
let bgRect = NSRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 210, yRadius: 210)

NSGraphicsContext.saveGraphicsState()
bgPath.addClip()
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.40, green: 0.46, blue: 0.96, alpha: 1.0),
    NSColor(srgbRed: 0.56, green: 0.29, blue: 0.86, alpha: 1.0)
])!
gradient.draw(in: bgRect, angle: -90)
NSGraphicsContext.restoreGraphicsState()

// Чат-«пузырь».
let bubbleRect = NSRect(x: 300, y: 392, width: 424, height: 300)
let bubble = NSBezierPath(roundedRect: bubbleRect, xRadius: 86, yRadius: 86)

// Хвостик пузыря (треугольник внизу слева).
let tail = NSBezierPath()
tail.move(to: NSPoint(x: 392, y: 410))
tail.line(to: NSPoint(x: 352, y: 320))
tail.line(to: NSPoint(x: 470, y: 410))
tail.close()

NSColor.white.setFill()
bubble.fill()
tail.fill()

// Три точки внутри пузыря.
let dotColor = NSColor(srgbRed: 0.50, green: 0.34, blue: 0.88, alpha: 1.0)
dotColor.setFill()
let dotY: CGFloat = 524
let dotR: CGFloat = 34
for cx in [Double(424), Double(512), Double(600)] {
    let dot = NSBezierPath(ovalIn: NSRect(x: CGFloat(cx) - dotR, y: dotY - dotR, width: dotR * 2, height: dotR * 2))
    dot.fill()
}

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
