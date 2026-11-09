import Cocoa
import ImageIO
import UniformTypeIdentifiers

private final class ViewerMemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func double(forKey key: String) -> Double { values[key] as? Double ?? 0 }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Double, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

private struct ViewerTestFailure: Error { let message: String }

@main
struct QuickCropViewerTests {
    private static var passed = 0

    private static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw ViewerTestFailure(message: message) }
        passed += 1
    }

    private static func waitFor(_ description: String, _ condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        try check(condition(), description)
    }

    private static func fixture(_ url: URL) throws {
        let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(output, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(output) else { throw ViewerTestFailure(message: "Fixture failed") }
    }

    private static func enter(repeatKey: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                        context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                        isARepeat: repeatKey, keyCode: 36)!
    }

    private static func key(_ code: UInt16, _ chars: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                        context: nil, characters: chars, charactersIgnoringModifiers: chars,
                        isARepeat: false, keyCode: code)!
    }

    static func main() throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let manager = FileManager.default
        let root = QuickCropFiles.canonicalURL(manager.temporaryDirectory.appendingPathComponent("quickcrop-viewer-\(UUID().uuidString)"))
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try manager.createDirectory(at: source, withIntermediateDirectories: true)
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        let images = (1...3).map { source.appendingPathComponent("0\($0).png") }
        for image in images { try fixture(image) }
        let alias = root.appendingPathComponent("alias")
        try manager.createSymbolicLink(at: alias, withDestinationURL: source)
        let preferences = QuickCropPreferences(defaults: ViewerMemoryDefaults())
        preferences.destinationFolder = destination
        let viewer = Viewer(frame: CGRect(x: 0, y: 0, width: 1100, height: 760), preferences: preferences)
        viewer.open(alias.appendingPathComponent("01.png"))
        try check(viewer.currentImageURL == images[0], "Viewer canonicalizes a folder alias")
        viewer.keyDown(with: enter())
        viewer.keyDown(with: enter())
        try waitFor("Enter opens the next remaining image") { viewer.currentImageURL == images[1] }
        try check(!manager.fileExists(atPath: images[0].path) && manager.fileExists(atPath: destination.appendingPathComponent("01.png").path),
                  "Enter performs a real move")
        try check(QuickCropFiles.images(in: destination).count == 1, "Two Enter events during a move do not move two images")
        try check(preferences.recentImage == images[1], "Remember the image shown after moving")
        viewer.keyDown(with: enter(repeatKey: true))
        try check(viewer.currentImageURL == images[1] && manager.fileExists(atPath: images[1].path),
                  "Holding Enter does not move the next image")
        viewer.keyDown(with: enter())
        try waitFor("Second move advances to the third image") { viewer.currentImageURL == images[2] }
        viewer.keyDown(with: enter())
        try waitFor("Last move shows an empty thumbnail browser") { viewer.currentImageURL == nil && viewer.canResizeThumbnails }
        try check(QuickCropFiles.images(in: source).isEmpty && QuickCropFiles.images(in: destination).count == 3,
                  "All three moves preserve the complete file set")
        try check(preferences.recentImage == nil && preferences.recentFolder?.path == source.path,
                  "After the last move, retain the source folder and clear the removed recent image")
        viewer.resizeThumbnails(by: 32)
        try check(preferences.thumbnailSize == 192, "Thumbnail command changes the stored display size")

        let retrySource = root.appendingPathComponent("retry-source")
        let retryDestination = root.appendingPathComponent("retry-destination")
        for directory in [retrySource, retryDestination] { try manager.createDirectory(at: directory, withIntermediateDirectories: true) }
        let retryFirst = retrySource.appendingPathComponent("01.png")
        let retryNext = retrySource.appendingPathComponent("02.png")
        try fixture(retryFirst)
        try fixture(retryNext)
        let retryPreferences = QuickCropPreferences(defaults: ViewerMemoryDefaults())
        retryPreferences.destinationFolder = retryDestination
        let lock = NSLock()
        var scans = 0
        let retryViewer = Viewer(frame: viewer.frame, preferences: retryPreferences, listImages: { folder in
            lock.lock()
            scans += 1
            let attempt = scans
            lock.unlock()
            if attempt == 1 { throw CocoaError(.fileReadNoPermission) }
            return try QuickCropFiles.images(in: folder)
        })
        retryViewer.open(retryFirst)
        try waitFor("Initial folder enumeration failed") {
            lock.lock(); defer { lock.unlock() }
            return scans == 1
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        retryViewer.keyDown(with: enter())
        try waitFor("Enter retries failed enumeration and opens the remaining sibling") { retryViewer.currentImageURL == retryNext }
        try check(manager.fileExists(atPath: retryNext.path) && QuickCropFiles.images(in: retryDestination).count == 1,
                  "A previous enumeration failure does not create a false empty state")

        let cropSource = root.appendingPathComponent("crop.png")
        let cropDestination = root.appendingPathComponent("crop-destination")
        try fixture(cropSource)
        try manager.createDirectory(at: cropDestination, withIntermediateDirectories: true)
        let cropPreferences = QuickCropPreferences(defaults: ViewerMemoryDefaults())
        cropPreferences.destinationFolder = cropDestination
        let cropViewer = Viewer(frame: viewer.frame, preferences: cropPreferences)
        cropViewer.open(cropSource)
        cropViewer.startCrop()
        try check(!cropViewer.canMoveImage, "Moving is disabled during crop")
        cropViewer.keyDown(with: enter())
        try check(cropViewer.canMoveImage && cropViewer.currentImageURL == cropSource,
                  "Enter applies crop and returns to image viewing")
        try check(manager.fileExists(atPath: cropSource.path) && QuickCropFiles.images(in: cropDestination).isEmpty,
                  "Enter during crop preserves the file in its source folder")
        try waitFor("The background crop write finishes", { !cropViewer.hasPendingCropWrites })
        try check((try? ImageDoc(cropSource)) != nil, "The cropped file is readable after the background write")
        let navFolder = root.appendingPathComponent("nav")
        try manager.createDirectory(at: navFolder, withIntermediateDirectories: true)
        let navImages = (1...6).map { navFolder.appendingPathComponent("0\($0).png") }
        for image in navImages { try fixture(image) }
        let navViewer = Viewer(frame: viewer.frame, preferences: QuickCropPreferences(defaults: ViewerMemoryDefaults()))
        navViewer.openFolder(navFolder)
        try waitFor("Thumbnail list loads") { navViewer.canTrash }
        for _ in 0..<3 { navViewer.keyDown(with: key(124)) }
        navViewer.keyDown(with: key(49, " "))
        try check(navViewer.currentImageURL == navImages[3], "Arrows + Space open the selected thumbnail")
        navViewer.keyDown(with: key(49, " "))
        try check(navViewer.currentImageURL == nil, "Space returns to thumbnails")
        try waitFor("Thumbnails reload after Space") { navViewer.canTrash }
        navViewer.keyDown(with: key(49, " "))
        try check(navViewer.currentImageURL == navImages[3], "Space return keeps the same image selected")
        navViewer.keyDown(with: key(124))
        try check(navViewer.currentImageURL == navImages[4], "Right arrow moves to the next image while viewing")
        navViewer.keyDown(with: key(53))
        try waitFor("Thumbnails reload after Esc") { navViewer.canTrash }
        navViewer.keyDown(with: key(49, " "))
        try check(navViewer.currentImageURL == navImages[4], "Esc return selects the image that was being viewed")
        navViewer.keyDown(with: key(49, " "))
        try waitFor("Thumbnails reload") { navViewer.canTrash }
        navViewer.keyDown(with: key(51))
        try waitFor("Delete in thumbnails trashes the selected image") { !manager.fileExists(atPath: navImages[4].path) }
        navViewer.keyDown(with: key(49, " "))
        try check(navViewer.currentImageURL == navImages[5], "After Delete the next thumbnail is selected")
        let scanLock = NSLock()
        var navScans = 0
        let countingViewer = Viewer(frame: viewer.frame, preferences: QuickCropPreferences(defaults: ViewerMemoryDefaults()),
                                    listImages: { folder in
            scanLock.lock(); navScans += 1; scanLock.unlock()
            return try QuickCropFiles.images(in: folder)
        })
        countingViewer.openFolder(navFolder)
        try waitFor("Counting viewer loads the folder") { countingViewer.canTrash }
        countingViewer.keyDown(with: key(49, " "))
        countingViewer.keyDown(with: key(49, " "))
        countingViewer.keyDown(with: key(49, " "))
        countingViewer.keyDown(with: key(53))
        try check(countingViewer.canTrash && countingViewer.currentImageURL == nil, "Returning to thumbnails is immediate")
        scanLock.lock(); let scanned = navScans; scanLock.unlock()
        try check(scanned == 1, "Returning from an image does not rescan the folder")
        print("PASS: \(passed) Viewer integration checks")
    }
}
