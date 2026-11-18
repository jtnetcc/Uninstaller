// 生成应用图标（1024×1024 PNG）
// 用法: swift Tools/make_icon.swift <输出路径>
import AppKit
import Foundation

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources/AppIcon-1024.png"

let canvas: CGFloat = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

// 背景圆角矩形（Big Sur 图标网格：824×824 居中）
let inset: CGFloat = 100
let bodyRect = NSRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
let body = NSBezierPath(roundedRect: bodyRect, xRadius: 186, yRadius: 186)

// 阴影
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 36
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor(srgbRed: 0.31, green: 0.36, blue: 0.95, alpha: 1).setFill()
body.fill()
NSGraphicsContext.current?.restoreGraphicsState()

// 渐变
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.36, green: 0.51, blue: 0.99, alpha: 1.0),
    NSColor(srgbRed: 0.44, green: 0.29, blue: 0.92, alpha: 1.0)
])
gradient?.draw(in: body, angle: -75)

// 高光
let highlight = NSBezierPath(roundedRect: bodyRect.insetBy(dx: 26, dy: 26), xRadius: 160, yRadius: 160)
NSColor.white.withAlphaComponent(0.10).setStroke()
highlight.lineWidth = 4
highlight.stroke()

// 中央符号：垃圾桶
let symbolSize = NSSize(width: 440, height: 440)
if let symbol = NSImage(systemSymbolName: "trash.fill", accessibilityDescription: nil)?
    .withSymbolConfiguration(.init(paletteColors: [.white])) {
    let rect = NSRect(
        x: (canvas - symbolSize.width) / 2,
        y: (canvas - symbolSize.height) / 2,
        width: symbolSize.width,
        height: symbolSize.height
    )
    symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("PNG 编码失败\n".utf8))
    exit(1)
}
try png.write(to: URL(fileURLWithPath: outputPath))
print("已生成: \(outputPath)")
