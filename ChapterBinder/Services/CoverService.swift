import AppKit
import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum CoverService {
    static let targetLongEdge: CGFloat = 1600
    static let maxLongEdge: CGFloat = 2400
    static let minLongEdge: CGFloat = 1400
    static let jpegQuality: CGFloat = 0.84

    static func processImage(at url: URL, destination: URL) throws {
        guard let image = NSImage(contentsOf: url) else {
            throw AppError.importFailed("Could not read cover image.")
        }
        try process(image, destination: destination)
    }

    static func process(_ image: NSImage, destination: URL) throws {
        let square = squared(image)
        let resized = resize(square, longEdge: targetLongEdge)
        guard let tiff = resized.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: jpegQuality])
        else {
            throw AppError.importFailed("Could not encode cover JPEG.")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jpeg.write(to: destination, options: .atomic)
    }

    static func extractEmbeddedCover(from audioURL: URL, destination: URL) async throws {
        let asset = AVURLAsset(url: audioURL)
        let metadata = (try? await asset.load(.metadata)) ?? []
        for item in metadata where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue), let image = NSImage(data: data) {
                try process(image, destination: destination)
                return
            }
        }
        throw AppError.importFailed("No embedded cover in \(audioURL.lastPathComponent)")
    }

    static func load(path: String?) -> NSImage? {
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
        return NSImage(contentsOf: URL(fileURLWithPath: path))
    }

    private static func squared(_ image: NSImage) -> NSImage {
        let size = image.size
        let side = min(size.width, size.height)
        let rect = NSRect(
            x: (size.width - side) / 2,
            y: (size.height - side) / 2,
            width: side,
            height: side
        )
        let out = NSImage(size: NSSize(width: side, height: side))
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: out.size), from: rect, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }

    private static func resize(_ image: NSImage, longEdge: CGFloat) -> NSImage {
        let size = image.size
        let longest = max(size.width, size.height)
        let target = min(max(longEdge, minLongEdge), maxLongEdge)
        if longest <= maxLongEdge && longest >= minLongEdge {
            return image
        }
        let scale = target / longest
        let newSize = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let out = NSImage(size: newSize)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: newSize), from: NSRect(origin: .zero, size: size), operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }
}
