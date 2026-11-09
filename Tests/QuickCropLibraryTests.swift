import Cocoa
import ImageIO
import UniformTypeIdentifiers

private final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func double(forKey key: String) -> Double { values[key] as? Double ?? 0 }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Double, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

private struct TestFailure: Error { let message: String }

@main
struct QuickCropLibraryTests {
    private static var passed = 0

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw TestFailure(message: message) }
        passed += 1
    }

    private static func expectFailure(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() }
        catch { passed += 1; return }
        throw TestFailure(message: message)
    }

    private static func image(at url: URL, orientation: Int = 1, type: UTType = .png) throws {
        let width = 1200, height = 600
        let pixels = Data(repeating: 128, count: width * height * 4)
        let provider = CGDataProvider(data: pixels as CFData)!
        let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                         bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let output = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(output, cg, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw TestFailure(message: "Could not create fixture") }
    }

    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("quickcrop-tests-\(UUID().uuidString)").standardizedFileURL
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        let empty = root.appendingPathComponent("empty")
        for directory in [source, destination, empty] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let first = source.appendingPathComponent("image2.PNG")
        let second = source.appendingPathComponent("image10.jpg")
        let original = Data("original image bytes".utf8)
        try original.write(to: first)
        try Data("second image bytes".utf8).write(to: second)
        try Data().write(to: source.appendingPathComponent(".hidden.png"))
        try Data().write(to: source.appendingPathComponent("notes.txt"))
        try manager.createDirectory(at: source.appendingPathComponent("directory.png"), withIntermediateDirectories: true)
        try check(QuickCropFiles.images(in: source) == [first, second], "Natural sort and supported regular files")
        try check(QuickCropFiles.images(in: empty).isEmpty, "Empty folder is valid")
        try expectFailure("Missing source folder must fail") {
            _ = try QuickCropFiles.images(in: root.appendingPathComponent("missing"))
        }

        let storage = MemoryDefaults()
        let preferences = QuickCropPreferences(defaults: storage)
        try check(preferences.destinationFolder == nil && preferences.recentFolder == nil && preferences.recentImage == nil,
                  "First launch has no saved paths")
        try check(preferences.thumbnailSize == 160, "Default thumbnail size")
        preferences.destinationFolder = destination
        preferences.remember(image: first)
        preferences.thumbnailSize = 224
        let restored = QuickCropPreferences(defaults: storage)
        try check(restored.destinationFolder?.path == destination.path && restored.recentFolder?.path == source.path && restored.recentImage == first,
                  "Restore destination, folder and image from stored preferences")
        try check(restored.thumbnailSize == 224, "Restore thumbnail size")
        try check(restored.imageToResume() == first, "Resume exact recent image")
        preferences.thumbnailSize = 10
        try check(preferences.thumbnailSize == 96, "Minimum thumbnail size")
        preferences.thumbnailSize = 999
        try check(preferences.thumbnailSize == 320, "Maximum thumbnail size")

        try expectFailure("Moving to same folder must fail") { _ = try QuickCropFiles.move(first, to: source) }
        let alias = root.appendingPathComponent("source-alias")
        try manager.createSymbolicLink(at: alias, withDestinationURL: source)
        try check(QuickCropFiles.images(in: alias) == [first, second], "Enumeration through a folder alias uses canonical image paths")
        try check(QuickCropFiles.canonicalURL(alias.appendingPathComponent(first.lastPathComponent)) == first,
                  "Opening through a folder alias uses the same identity as enumeration")
        try expectFailure("Moving to a symlink of the same folder must fail") { _ = try QuickCropFiles.move(first, to: alias) }
        try expectFailure("Missing destination must fail") {
            _ = try QuickCropFiles.move(first, to: root.appendingPathComponent("missing"))
        }
        try expectFailure("A regular file cannot be a destination") { _ = try QuickCropFiles.move(first, to: second) }
        let fileAlias = source.appendingPathComponent("linked-image.png")
        try manager.createSymbolicLink(at: fileAlias, withDestinationURL: first)
        try check(QuickCropFiles.canonicalURL(fileAlias).path == fileAlias.path, "Canonicalization preserves a file symlink entry")
        try expectFailure("A file symlink must not move its target") { _ = try QuickCropFiles.move(fileAlias, to: destination) }
        try check((try fileAlias.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true && Data(contentsOf: first) == original,
                  "Rejected symlink move preserves both link and target")
        try manager.removeItem(at: fileAlias)
        try check(Data(contentsOf: first) == original, "Failed moves preserve source bytes")

        let collision = destination.appendingPathComponent(first.lastPathComponent)
        let anotherCollision = destination.appendingPathComponent("image2 (1).PNG")
        let existing = Data("existing destination image".utf8)
        try existing.write(to: collision)
        try existing.write(to: anotherCollision)
        let moved = try QuickCropFiles.move(first, to: destination)
        try check(moved.lastPathComponent == "image2 (2).PNG", "Choose unused name after multiple conflicts")
        try check(Data(contentsOf: collision) == existing && Data(contentsOf: anotherCollision) == existing,
                  "Never overwrite either existing destination file")
        try check(!manager.fileExists(atPath: first.path) && Data(contentsOf: moved) == original,
                  "A move removes source and preserves destination bytes")
        try check(restored.imageToResume() == second, "Resume a remaining image if recent image was externally moved")
        preferences.forgetImage(ifMatching: second)
        try check(preferences.recentImage == first, "Only clear the matching recent image")
        preferences.forgetImage(ifMatching: first)
        try check(preferences.recentImage == nil && preferences.recentFolder?.path == source.path,
                  "Clear removed image and retain source folder")
        preferences.remember(image: second)
        let secondMoved = try QuickCropFiles.move(second, to: destination)
        try check(secondMoved.lastPathComponent == second.lastPathComponent && QuickCropFiles.images(in: source).isEmpty,
                  "Last image moves without adding a suffix")
        try check(preferences.imageToResume() == nil, "No remaining image returns empty state")

        let preview = root.appendingPathComponent("preview.png")
        try image(at: preview)
        let thumbnail = QuickCropThumbnailLoader.thumbnail(for: preview)
        try check(thumbnail?.width == 640 && thumbnail?.height == 320,
                  "Thumbnail is downsampled with the source aspect ratio")
        let rotated = root.appendingPathComponent("rotated.jpg")
        try image(at: rotated, orientation: 6, type: .jpeg)
        let rotatedThumbnail = QuickCropThumbnailLoader.thumbnail(for: rotated)
        try check(rotatedThumbnail?.width == 320 && rotatedThumbnail?.height == 640,
                  "Thumbnail respects EXIF orientation")
        let gif = root.appendingPathComponent("preview.gif")
        try image(at: gif, type: .gif)
        try check(QuickCropThumbnailLoader.thumbnail(for: gif) != nil, "GIF thumbnail is readable")
        try check(QuickCropThumbnailLoader.thumbnail(for: collision) == nil, "Broken image yields a placeholder")
        print("PASS: \(passed) file, preference and thumbnail checks")
    }
}
