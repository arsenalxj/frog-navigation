import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

struct DecodedIcon: @unchecked Sendable {
    let image: CGImage
    let pixelSize: Int

    static func decode(_ data: Data) -> DecodedIcon? {
        guard data.count <= IconRequestKind.image.byteLimit,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        var preferredIndex: Int?
        var preferredSize = 0
        for index in 0..<min(CGImageSourceGetCount(source), 32) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 8192, height <= 8192,
                  width * height <= 16_777_216 else { continue }
            let size = min(width, height)
            if size > preferredSize { preferredSize = size; preferredIndex = index }
        }
        guard let preferredIndex,
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, preferredIndex, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return DecodedIcon(image: thumbnail, pixelSize: preferredSize)
    }

    func pngData() -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

struct IconCacheEntry: Codable, Sendable {
    let originalPageURL: String
    let finalPageURL: String
    let resourceURL: String
    let relativePath: String
    let updatedAt: Date
}

private struct IconCacheIndex: Codable {
    var schemaVersion = 1
    var entries: [String: IconCacheEntry] = [:]
}

protocol IconCaching: Sendable {
    func read(for page: URL) async -> DecodedIcon?
    func save(_ icon: DecodedIcon, originalPage: URL, finalPage: URL, resource: URL) async throws
}

/// 图标缓存独立于用户书签目录，所有磁盘读取和解码都在此 actor 执行。
actor IconCache: IconCaching {
    let directory: URL
    private var index: IconCacheIndex?

    init(directory: URL) { self.directory = directory }

    func read(for page: URL) -> DecodedIcon? {
        loadIndexIfNeeded()
        let key = hash(page)
        guard let entry = index?.entries[key], entry.originalPageURL == page.absoluteString,
              entry.relativePath == "icons/\(key).png" else { return nil }
        let file = directory.appendingPathComponent(entry.relativePath)
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 2 * 1024 * 1024, let data = try? Data(contentsOf: file) else { return nil }
        return DecodedIcon.decode(data)
    }

    func save(_ icon: DecodedIcon, originalPage: URL, finalPage: URL, resource: URL) throws {
        loadIndexIfNeeded()
        guard let data = icon.pngData() else { throw IconFetchError.invalidImage }
        let icons = directory.appendingPathComponent("icons", isDirectory: true)
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        let key = hash(originalPage)
        let relativePath = "icons/\(key).png"
        try data.write(to: directory.appendingPathComponent(relativePath), options: .atomic)
        var next = index ?? IconCacheIndex()
        next.entries[key] = IconCacheEntry(originalPageURL: originalPage.absoluteString, finalPageURL: finalPage.absoluteString,
                                          resourceURL: resource.absoluteString, relativePath: relativePath, updatedAt: Date())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(next).write(to: directory.appendingPathComponent("icons-index.json"), options: .atomic)
        index = next
    }

    private func loadIndexIfNeeded() {
        guard index == nil else { return }
        let file = directory.appendingPathComponent("icons-index.json")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 16 * 1024 * 1024,
              let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode(IconCacheIndex.self, from: data),
              decoded.schemaVersion == 1 else { index = IconCacheIndex(); return }
        index = decoded
    }

    private func hash(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
