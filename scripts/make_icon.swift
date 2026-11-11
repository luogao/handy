// 生成 Handy 的应用图标：深色圆角底 + 白色 mic.fill，逐尺寸重画后打成 .icns。
//
// 为什么逐尺寸重画而不是缩 1024：16/32px 下把大图硬缩，麦克风会糊成一团，
// 直接按目标像素渲染，字形的笔画才是清楚的。
//
// 用法: swift scripts/make_icon.swift [输出目录，默认 Resources]
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"

let variants: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

func render(px: Int) -> Data? {
    let size = CGFloat(px)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }
    ctx.setShouldAntialias(true)

    // macOS 图标网格：内容区约 824/1024，四周留白；圆角跟着内容区走。
    let inset = size * 0.082
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.225
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    let top = NSColor(calibratedRed: 0.153, green: 0.478, blue: 0.588, alpha: 1)   // 青
    let bottom = NSColor(calibratedRed: 0.043, green: 0.110, blue: 0.157, alpha: 1) // 深蓝黑
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [top.cgColor, bottom.cgColor] as CFArray,
                                 locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: size),
                               end: CGPoint(x: 0, y: 0),
                               options: [])
    }

    // 中心柔光：让白麦克风在深底上「亮着」，而不是硬贴上去
    let center = CGPoint(x: size / 2, y: size / 2)
    if let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: [NSColor.white.withAlphaComponent(0.18).cgColor,
                                      NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                             locations: [0, 1]) {
        ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: rect.width * 0.46, options: [])
    }
    ctx.restoreGState()

    // 内描边：小尺寸下这一步几乎看不见，大尺寸给图标一点边缘厚度
    ctx.addPath(path)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
    ctx.setLineWidth(max(size * 0.003, 0.6))
    ctx.strokePath()

    // 麦克风用 SF Symbol（系统自带，不引入第三方素材）
    let config = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    guard let symbol = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { return nil }

    let target = size * 0.54
    let ratio = min(target / symbol.size.width, target / symbol.size.height)
    let width = symbol.size.width * ratio
    let height = symbol.size.height * ratio
    symbol.draw(in: NSRect(x: (size - width) / 2, y: (size - height) / 2,
                           width: width, height: height))

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return nil }
    return png
}

let fm = FileManager.default
let outURL = URL(fileURLWithPath: outDir)
try fm.createDirectory(at: outURL, withIntermediateDirectories: true)

let iconset = outURL.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

for variant in variants {
    guard let png = render(px: variant.px) else {
        FileHandle.standardError.write(Data("render \(variant.name) failed\n".utf8))
        exit(1)
    }
    try png.write(to: iconset.appendingPathComponent(variant.name))
}

// 1024 母版留一份，方便以后改设计时对比
if let master = render(px: 1024) {
    try master.write(to: outURL.appendingPathComponent("icon-1024.png"))
}

let icns = outURL.appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

// iconset 是中间产物，源是这份脚本，不留着占仓库
try? fm.removeItem(at: iconset)
print("wrote \(icns.path) (\(variants.count) sizes)")
