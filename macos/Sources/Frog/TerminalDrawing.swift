import AppKit

@MainActor
enum TerminalDrawing {
    static let paper = color(0xFFFEF8), surface = color(0xF8F4ED), line = color(0xE4DFD7)
    static let ink = color(0x0F1A20), ink2 = color(0x3B3A3E), muted = color(0x695E45)
    static let green = color(0x0D5E3A), pine = color(0x2E4B26), purple = color(0x7E1671)
    static let blue = color(0x1661AB), teal = color(0x126E82), red = color(0x7C1823), amber = color(0x862617)
    static let yellow = color(0xE6C24D), lemon = color(0xF8DF72), mint = color(0xADD5A2), forest = color(0x1A3B2E)
    static let tiles = [green, purple, blue, red, amber, teal, pine, forest]
    private struct FontKey: Hashable { let size: CGFloat; let bold: Bool }
    private static var fonts: [FontKey: NSFont] = [:]
    private struct IconKey: Hashable { let name: String; let color: NSColor }
    private static var sourceIcons: [String: NSImage] = [:]
    private static var tintedIcons: [IconKey: NSImage] = [:]
    private static let paragraph: NSParagraphStyle = {
        let value = NSMutableParagraphStyle()
        value.lineBreakMode = .byTruncatingTail
        return value
    }()

    static func color(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }

    static func font(_ size: CGFloat, bold: Bool = false) -> NSFont {
        let key = FontKey(size: size, bold: bold)
        if let font = fonts[key] { return font }
        let font = NSFont(name: bold ? "SFMono-Semibold" : "SFMono-Regular", size: size)
            ?? NSFont(name: bold ? "Menlo-Bold" : "Menlo-Regular", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
        fonts[key] = font
        return font
    }

    static func width(_ text: String, size: CGFloat, bold: Bool = false) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font(size, bold: bold)]).width
    }

    static func text(_ text: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat = 14,
                     color: NSColor? = nil, bold: Bool = false, maxWidth: CGFloat = 1360,
                     align: NSTextAlignment = .left) {
        let font = font(size, bold: bold)
        let width = min(maxWidth, self.width(text, size: size, bold: bold) + 1)
        let left = align == .right ? x - width : align == .center ? x - width / 2 : x
        let height = font.ascender - font.descender + font.leading + 2
        (text as NSString).draw(in: NSRect(x: left, y: y - height / 2, width: max(0, width), height: height),
            withAttributes: [.font: font, .foregroundColor: color ?? ink, .paragraphStyle: paragraph])
    }

    static func rect(_ rect: NSRect, _ color: NSColor, radius: CGFloat = 0) {
        color.setFill()
        if radius > 0 { NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill() }
        else { rect.fill() }
    }

    static func rule(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, color: NSColor? = nil, height: CGFloat = 1) {
        rect(NSRect(x: x, y: y, width: width, height: height), color ?? line)
    }

    static func tile(_ item: TerminalItem, x: CGFloat, y: CGFloat) {
        var hash: UInt32 = 0
        for unit in item.id.utf16 { hash = hash &* 31 &+ UInt32(unit) }
        rect(NSRect(x: x, y: y - 10, width: 20, height: 20), tiles[Int(hash % 8)], radius: 3)
        let initial = item.title.unicodeScalars.first.map { String($0).uppercased() } ?? "?"
        text(initial, x + 10, y + 0.5, size: 11, color: paper, bold: true, maxWidth: 20, align: .center)
    }

    static func level(_ level: TerminalLevel) -> NSColor {
        switch level {
        case .normal: return ink2
        case .muted: return muted
        case .info, .command: return teal
        case .success: return green
        case .warning: return amber
        case .error: return red
        }
    }

    @discardableResult
    static func key(_ label: String, x: CGFloat, y: CGFloat, dark: Bool = false, size: CGFloat = 11.5) -> CGFloat {
        let width = max(24, self.width(label, size: size) + 12)
        let bounds = NSRect(x: x, y: y - 11, width: width, height: 22)
        if !dark { rect(bounds, surface, radius: 2) }
        (dark ? paper.withAlphaComponent(0.35) : line).setStroke()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).stroke()
        text(label, x + width / 2, y + 0.5, size: size, color: dark ? paper : ink2, align: .center)
        return width
    }

    static func icon(_ name: String, x: CGFloat, y: CGFloat, size: CGFloat = 16, color: NSColor) {
        let key = IconKey(name: name, color: color)
        let image: NSImage
        if let cached = tintedIcons[key] { image = cached }
        else {
            let source: NSImage
            if let cached = sourceIcons[name] { source = cached }
            else {
                #if SWIFT_PACKAGE
                let bundle = Bundle.module
                #else
                let bundle = Bundle.main
                #endif
                let file = "terminal-\(name)"
                let url = bundle.url(forResource: file, withExtension: "svg", subdirectory: "Assets")
                    ?? bundle.url(forResource: file, withExtension: "svg")
                guard let url, let loaded = NSImage(contentsOf: url) else {
                    NSLog("Missing or undecodable terminal SVG: %@", file)
                    let blank = NSImage(size: NSSize(width: 16, height: 16))
                    tintedIcons[key] = blank
                    return
                }
                sourceIcons[name] = loaded
                source = loaded
            }
            // AppKit 在目标显示倍率下绘制原始 SVG；着色结果按资源与颜色缓存。
            image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
                source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                color.setFill()
                rect.fill(using: .sourceAtop)
                return true
            }
            tintedIcons[key] = image
        }
        image.draw(in: NSRect(x: x, y: y, width: size, height: size), from: .zero,
                   operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

