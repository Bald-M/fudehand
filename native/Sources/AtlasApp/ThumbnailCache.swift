import AppKit
import CryptoKit

/// 侧栏缩略图的本地缓存：每个工作区一个目录，每个作品一张 PNG。
struct ThumbnailCache {
    static let width = 320
    let directory: URL

    static var defaultBase: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("界面图鉴", isDirectory: true).appendingPathComponent("thumbnails", isDirectory: true)
    }

    /// 以工作区路径的哈希区分目录，不同检出的同名作品互不覆盖。
    static func directory(for root: URL, base: URL = defaultBase) -> URL {
        let digest = SHA256.hash(data: Data(root.standardizedFileURL.path.utf8))
        let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent(name, isDirectory: true)
    }

    private func file(_ id: String) -> URL { directory.appendingPathComponent("\(id).png") }

    func load(_ id: String) -> NSImage? { NSImage(contentsOf: file(id)) }

    /// 把截图等比缩小到 `width` 像素宽后写入，返回写入的图像。
    @discardableResult
    func save(_ png: Data, id: String) throws -> NSImage {
        guard let source = NSBitmapImageRep(data: png), source.pixelsWide > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let width = min(Self.width, source.pixelsWide)
        let height = max(1, Int((Double(source.pixelsHigh) * Double(width) / Double(source.pixelsWide)).rounded()))
        guard let target = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { throw CocoaError(.fileWriteUnknown) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: target)
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = target.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file(id), options: .atomic)
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(target)
        return image
    }
}
