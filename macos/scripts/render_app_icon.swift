#!/usr/bin/swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// 完整缩放用户源图；原有白底与构图保持不变，不裁剪或重画主体。
func png(_ source: CGImage, size: Int) throws -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw NSError(domain: "FrogIcon", code: 1)
    }
    context.interpolationQuality = .high
    context.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))
    let data = NSMutableData()
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "FrogIcon", code: 2)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "FrogIcon", code: 3) }
    return data as Data
}

func writeICO(_ source: CGImage, to url: URL) throws {
    let sizes = [16, 24, 32, 48, 64, 128, 256]
    let frames = try sizes.map { try png(source, size: $0) }
    var data = Data()
    func word(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
    func dword(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
    word(0); word(1); word(UInt16(sizes.count))
    var offset = 6 + sizes.count * 16
    for (size, frame) in zip(sizes, frames) {
        let side = UInt8(size == 256 ? 0 : size)
        data.append(contentsOf: [side, side, 0, 0]); word(1); word(32)
        dword(UInt32(frame.count)); dword(UInt32(offset)); offset += frame.count
    }
    for frame in frames { data.append(frame) }
    try data.write(to: url, options: .atomic)
}

guard CommandLine.arguments.count == 4 || CommandLine.arguments.count == 5 else {
    fputs("用法：render_app_icon.swift <源PNG> <Resources目录> <预览目录> [Windows ICO路径]\n", stderr)
    exit(1)
}
do {
    let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let resources = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let previews = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
    guard let decoder = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
          let source = CGImageSourceCreateImageAtIndex(decoder, 0, nil), source.width == source.height else {
        throw NSError(domain: "FrogIcon", code: 4, userInfo: [NSLocalizedDescriptionKey: "源图必须是有效的正方形图片"])
    }
    let icon = resources.appendingPathComponent("AppIcon.icon", isDirectory: true)
    let assets = icon.appendingPathComponent("Assets", isDirectory: true)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
    let image = try png(source, size: 1024)
    try image.write(to: resources.appendingPathComponent("AppIcon-1024.png"), options: .atomic)
    try image.write(to: assets.appendingPathComponent("Frog.png"), options: .atomic)
    let document: [String: Any] = [
        "fill": ["solid": "srgb:1.00000,1.00000,1.00000,1.00000"],
        "groups": [[
            "name": "青蛙导航",
            "layers": [["image-name": "Frog.png", "name": "青蛙", "glass": false]],
            "shadow": ["kind": "neutral", "opacity": 0.0],
            "specular": false,
            "translucency": ["enabled": false, "value": 0.0]
        ]],
        "supported-platforms": ["squares": "shared", "circles": []]
    ]
    let json = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try json.write(to: icon.appendingPathComponent("icon.json"), options: .atomic)
    if CommandLine.arguments.count == 5 {
        try writeICO(source, to: URL(fileURLWithPath: CommandLine.arguments[4]))
    }
    print("已从原图生成 1024 × 1024 青蛙图标及 Icon Composer 文档。")
} catch {
    fputs("图标生成失败：\(error.localizedDescription)\n", stderr)
    exit(1)
}
