import Cocoa
import ImageIO
import UniformTypeIdentifiers
import CoreImage

final class QCError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

final class ImageDoc {
    let url: URL
    let source: CGImageSource
    let cg: CGImage
    let image: NSImage
    let size: CGSize
    let frames: Int
    let frameDurations: [TimeInterval]
    /// Frame count of the file on disk. Equals `frames`, except for an in-memory crop
    /// preview of an animated file, which shows one still frame until the write finishes.
    let fileFrames: Int

    /// Shows already-cropped pixels at once while the file is re-encoded in the background.
    init(cropPreview cg: CGImage, of original: ImageDoc) {
        url = original.url
        source = original.source
        self.cg = cg
        size = CGSize(width: cg.width, height: cg.height)
        image = NSImage(cgImage: cg, size: size)
        frames = 1
        frameDurations = [0.1]
        fileFrames = original.fileFrames
    }

    init(_ url: URL) throws {
        self.url = QuickCropFiles.canonicalURL(url)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let base = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw QCError("Could not read the image.")
        }
        self.source = source
        frames = CGImageSourceGetCount(source)
        fileFrames = frames

        var normalized = base
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let raw = props[kCGImagePropertyOrientation] as? NSNumber, raw.int32Value != 1 {
            let ci = CIImage(cgImage: base).oriented(forExifOrientation: raw.int32Value)
            if let fixed = CIContext().createCGImage(ci, from: ci.extent) { normalized = fixed }
        }
        cg = normalized
        size = CGSize(width: normalized.width, height: normalized.height)
        image = NSImage(cgImage: normalized, size: size)

        if url.pathExtension.lowercased() == "webp" && frames > 1 {
            // Animated WebP playback uses libwebp's sequential decoder, which
            // supplies frame timestamps lazily. Avoid scanning every frame here.
            frameDurations = Array(repeating:0.1, count:frames)
        } else {
            var durations:[TimeInterval] = []
            for i in 0..<frames {
                var delay:TimeInterval = 0.1
                if let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString:Any],
                   let gif = props[kCGImagePropertyGIFDictionary] as? [CFString:Any] {
                    if let v = gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber { delay = v.doubleValue }
                    else if let v = gif[kCGImagePropertyGIFDelayTime] as? NSNumber { delay = v.doubleValue }
                }
                durations.append(max(0.02, delay))
            }
            frameDurations = durations
        }
    }
}

final class Viewer: NSView {
    private enum Presentation { case home, thumbnails, image }
    private enum DragMode {
        case none, fresh, move, left, right, top, bottom
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private static let cropHitRadius: CGFloat = 18
    private var cropTrackingArea: NSTrackingArea?

    weak var hostWindow: NSWindow?
    let preferences: QuickCropPreferences
    private let listImages: (URL) throws -> [URL]
    private let welcome = QuickCropWelcomeView()
    private let browser = QuickCropThumbnailBrowser()
    private let shortcutsOverlay = QuickCropShortcutsOverlay()
    private var shortcutsKeyMonitor: Any?
    private var presentation: Presentation = .home
    private var currentFolder: URL?
    private var fileListNeedsRefresh = false
    private var moveBusy = false
    private var doc: ImageDoc?
    private var files: [URL] = []
    private var index = 0
    private var cropMode = false
    private var crop = CGRect.zero
    private var anchor = CGPoint.zero
    private var dragMode: DragMode = .none
    private var original = CGRect.zero
    private struct WebPQueuedFrame {
        let image: NSImage
        let duration: TimeInterval
    }

    private var animationTimer: Timer?
    private var animationFrame = 0
    private var animationImage: NSImage?
    private var webPFrameQueue: [WebPQueuedFrame] = []
    private var webPInitialDuration: TimeInterval?
    private var animationFrameCache: [Int:NSImage] = [:]
    private var animationRequestedFrames: Set<Int> = []
    private var animationGeneration = UUID()
    private let animationDecodeQueue = DispatchQueue(label:"com.khanh.quickcrop.animation", qos:.userInitiated)
    private var zoomScale: CGFloat = 1.0
    private var panOffset = CGPoint.zero
    private struct TrashRequest {
        let url: URL
        let removedIndex: Int
    }

    private var fileListGeneration = UUID()
    private let fileListQueue = DispatchQueue(label:"com.khanh.quickcrop.filelist", qos:.userInitiated)
    private var trashPending: [TrashRequest] = []
    /// Crop encodes/writes run here, one at a time, in order; move and trash wait for it.
    private let cropWriteQueue = DispatchQueue(label:"com.khanh.quickcrop.cropwrite", qos:.userInitiated)
    private var pendingCropWrites: [URL:Int] = [:]
    var hasPendingCropWrites: Bool { !pendingCropWrites.isEmpty }
    private var trashBusy = false
    private var pendingSelection: URL?
    private var listIsFolder = false
    private let exts = QuickCropFiles.extensions

    var canResizeThumbnails: Bool { presentation == .thumbnails && !moveBusy }
    var canEditImage: Bool { presentation == .image && doc != nil && !moveBusy }
    var canTrash: Bool { canEditImage || (presentation == .thumbnails && !moveBusy && !files.isEmpty) }
    var canMoveImage: Bool { canEditImage && !cropMode && !trashBusy && trashPending.isEmpty }
    var currentImageURL: URL? { doc?.url }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override convenience init(frame: CGRect) {
        self.init(frame: frame, preferences: QuickCropPreferences())
    }

    init(frame: CGRect, preferences: QuickCropPreferences,
         listImages: @escaping (URL) throws -> [URL] = QuickCropFiles.images) {
        self.preferences = preferences
        self.listImages = listImages
        super.init(frame: frame)
        wantsLayer = true
        appearance = NSAppearance(named: .darkAqua)
        registerForDraggedTypes([.fileURL])
        for child in [welcome, browser] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: leadingAnchor),
                child.trailingAnchor.constraint(equalTo: trailingAnchor),
                child.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
                child.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
        shortcutsOverlay.translatesAutoresizingMaskIntoConstraints = false
        shortcutsOverlay.isHidden = true
        shortcutsOverlay.onClose = { [weak self] in self?.toggleShortcuts() }
        shortcutsOverlay.onChooseDestination = { [weak self] in self?.chooseDestinationFolder() }
        addSubview(shortcutsOverlay)
        NSLayoutConstraint.activate([
            shortcutsOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            shortcutsOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            shortcutsOverlay.topAnchor.constraint(equalTo: topAnchor),
            shortcutsOverlay.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        welcome.onOpenImage = { [weak self] in self?.chooseImage() }
        welcome.onOpenFolder = { [weak self] in self?.chooseFolder() }
        welcome.onRecentFolder = { [weak self] in self?.openRecentFolder() }
        welcome.onRecentImage = { [weak self] in self?.openRecentImage() }
        welcome.onSettings = { [weak self] in self?.showSettings() }
        browser.onOpen = { [weak self] url in self?.open(url) }
        browser.onHome = { [weak self] in self?.showHome() }
        browser.onChooseFolder = { [weak self] in self?.chooseFolder() }
        browser.onSmaller = { [weak self] in self?.resizeThumbnails(by: -32) }
        browser.onLarger = { [weak self] in self?.resizeThumbnails(by: 32) }
        welcome.refresh(preferences)
        browser.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cropTrackingArea {
            removeTrackingArea(cropTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cropTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateCropCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCropCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    private func updateCropCursor(at point: CGPoint) {
        guard cropMode else {
            NSCursor.arrow.set()
            return
        }

        switch hitMode(at: point) {
        case .left, .right:
            NSCursor.resizeLeftRight.set()
        case .top, .bottom:
            NSCursor.resizeUpDown.set()
        case .topLeft:
            if #available(macOS 15.0, *) { setCornerResizeCursor(position: .topLeft) }
            else { NSCursor.resizeUpDown.set() }
        case .topRight:
            if #available(macOS 15.0, *) { setCornerResizeCursor(position: .topRight) }
            else { NSCursor.resizeLeftRight.set() }
        case .bottomLeft:
            if #available(macOS 15.0, *) { setCornerResizeCursor(position: .bottomLeft) }
            else { NSCursor.resizeLeftRight.set() }
        case .bottomRight:
            if #available(macOS 15.0, *) { setCornerResizeCursor(position: .bottomRight) }
            else { NSCursor.resizeUpDown.set() }
        case .move:
            NSCursor.openHand.set()
        case .fresh:
            NSCursor.crosshair.set()
        case .none:
            NSCursor.arrow.set()
        }
    }

    @available(macOS 15.0, *)
    private func setCornerResizeCursor(position: NSCursor.FrameResizePosition) {
        NSCursor.frameResize(position: position, directions: .all).set()
    }

    func open(_ url: URL) {
        guard !moveBusy else { return }
        let url = QuickCropFiles.canonicalURL(url)
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            openFolder(url)
            return
        }
        guard exts.contains(url.pathExtension.lowercased()) else {
            alert("QuickCrop only supports WebP, GIF, JPG/JPEG and PNG.")
            return
        }
        guard show(url) else { return }
        fileListGeneration = UUID()
        files = [url]
        listIsFolder = false
        index = 0
        fileListNeedsRefresh = true
        updateTitle()
        rebuildListInBackground(around:url, generation:fileListGeneration)
    }

    func openList(_ urls:[URL]) {
        guard !moveBusy else { return }
        let ordered = urls.map { QuickCropFiles.canonicalURL($0) }.filter { exts.contains($0.pathExtension.lowercased()) }
        guard let first = ordered.first else {
            alert("The selection contains no WebP, GIF, JPG/JPEG or PNG images.")
            return
        }
        guard show(first) else { return }
        fileListGeneration = UUID()
        fileListNeedsRefresh = false
        files = ordered
        listIsFolder = false
        index = 0
        updateTitle()
    }

    @discardableResult
    private func show(_ url: URL) -> Bool {
        do {
            if pendingCropWrites[QuickCropFiles.canonicalURL(url)] != nil { cropWriteQueue.sync {} }
            let newDoc = try ImageDoc(url)
            stopAnimation()
            doc = newDoc
            currentFolder = url.deletingLastPathComponent()
            presentation = .image
            cropMode = false
            crop = .zero
            zoomScale = 1.0
            panOffset = .zero
            configureAnimation(for:newDoc)
            preferences.remember(image: url)
            updatePresentation()
            updateTitle()
            needsDisplay = true
            window?.makeFirstResponder(self)
            return true
        } catch {
            alert(error.localizedDescription)
            return false
        }
    }

    private func rebuildListInBackground(around url: URL, generation: UUID) {
        let dir = url.deletingLastPathComponent()
        let listImages = self.listImages
        fileListQueue.async { [weak self] in
            let built = try? listImages(dir)
            DispatchQueue.main.async {
                guard let self,
                      self.fileListGeneration == generation,
                      let activeURL = self.doc?.url else { return }
                if let built, let activeIndex = built.firstIndex(of: activeURL) {
                    self.files = built
                    self.listIsFolder = true
                    self.index = activeIndex
                    self.fileListNeedsRefresh = false
                }
                self.updateTitle()
            }
        }
    }

    private func clearImage() {
        stopAnimation()
        doc = nil
        animationImage = nil
        cropMode = false
        crop = .zero
        dragMode = .none
    }

    private func updatePresentation() {
        welcome.isHidden = presentation != .home
        browser.isHidden = presentation != .thumbnails
        needsDisplay = true
    }

    func showHome() {
        guard !moveBusy else { return }
        fileListGeneration = UUID()
        fileListNeedsRefresh = false
        clearImage()
        presentation = .home
        welcome.refresh(preferences)
        updatePresentation()
        updateTitle()
        window?.makeFirstResponder(self)
    }

    func openFolder(_ folder: URL) {
        guard !moveBusy else { return }
        let folder = QuickCropFiles.canonicalURL(folder)
        guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            alert("The folder no longer exists. Please choose it again with Open Folder.")
            return
        }
        let generation = UUID()
        fileListGeneration = generation
        fileListNeedsRefresh = true
        currentFolder = folder
        files = []
        index = 0
        clearImage()
        presentation = .thumbnails
        browser.display(folder: folder, images: [], size: preferences.thumbnailSize, loading: true)
        updatePresentation()
        updateTitle()
        window?.makeFirstResponder(self)
        let listImages = self.listImages
        fileListQueue.async { [weak self] in
            let result = Result { try listImages(folder) }
            DispatchQueue.main.async {
                guard let self, self.fileListGeneration == generation else { return }
                self.fileListNeedsRefresh = false
                switch result {
                case .success(let images):
                    self.files = images
                    self.listIsFolder = true
                    self.preferences.remember(folder: folder)
                    self.index = self.pendingSelection.flatMap { images.firstIndex(of: $0) } ?? 0
                    self.pendingSelection = nil
                    self.browser.display(folder: folder, images: images, size: self.preferences.thumbnailSize, selecting: self.index)
                    self.updateTitle()
                case .failure(let error):
                    self.showHome()
                    self.alert(error.localizedDescription)
                }
            }
        }
    }

    func showThumbnails() {
        // Viewing an image and the folder listing is already loaded: go back immediately without rescanning the folder.
        if presentation == .image, listIsFolder, !fileListNeedsRefresh, !files.isEmpty, currentFolder != nil {
            fileListGeneration = UUID()
            clearImage()
            presentCurrentThumbnails()
            window?.makeFirstResponder(self)
            return
        }
        if let url = doc?.url { pendingSelection = url }
        if let folder = currentFolder ?? preferences.recentFolder { openFolder(folder) }
    }

    func openRecentFolder() {
        if let folder = preferences.recentFolder { openFolder(folder) }
    }

    func openRecentImage() {
        guard !moveBusy else { return }
        let generation = UUID()
        fileListGeneration = generation
        fileListQueue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.preferences.imageToResume() }
            DispatchQueue.main.async {
                guard self.fileListGeneration == generation else { return }
                switch result {
                case .success(let image):
                    if let image { self.open(image) }
                    else { self.openRecentFolder() }
                case .failure(let error): self.alert(error.localizedDescription)
                }
            }
        }
    }

    func resizeThumbnails(by amount: CGFloat) {
        guard canResizeThumbnails else { return }
        preferences.thumbnailSize += amount
        browser.resizeThumbnails(to: preferences.thumbnailSize)
    }

    func chooseImage() {
        guard !moveBusy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = preferences.recentFolder
        if panel.runModal() == .OK {
            if panel.urls.count > 1 { openList(panel.urls) }
            else if let url = panel.url { open(url) }
        }
    }

    func chooseFolder() {
        guard !moveBusy else { return }
        let panel = NSOpenPanel()
        panel.title = "Open Image Folder"
        panel.prompt = "Open Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = preferences.recentFolder
        if panel.runModal() == .OK, let url = panel.url { openFolder(url) }
    }

    /// Opens the combined Settings & Shortcuts panel (⌘, toggles it).
    func showSettings() {
        if !isShowingShortcuts { toggleShortcuts() }
    }

    private func chooseDestinationFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Destination Folder"
        panel.message = "Press Enter while viewing an image to move it to this folder."
        panel.prompt = "Use Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = preferences.destinationFolder ?? preferences.recentFolder
        if panel.runModal() == .OK, let url = panel.url {
            preferences.destinationFolder = url
            welcome.refresh(preferences)
            shortcutsOverlay.destinationPath = url.path
            needsDisplay = true
        }
    }

    func moveCurrent() {
        guard canEditImage, !cropMode, !trashBusy, trashPending.isEmpty, let source = doc?.url else { return }
        if preferences.destinationFolder == nil { chooseDestinationFolder() }
        guard let destination = preferences.destinationFolder else { return }
        let generation = UUID()
        let needsList = fileListNeedsRefresh
        let listImages = self.listImages
        let existingFiles = files
        let cropWrites = cropWriteQueue
        fileListGeneration = generation
        fileListNeedsRefresh = false
        moveBusy = true
        updateTitle()
        needsDisplay = true
        fileListQueue.async { [weak self] in
            cropWrites.sync {}   // finish any crop still being written to this file
            let result = Result { () throws -> [URL] in
                let list = needsList ? try listImages(source.deletingLastPathComponent()) : existingFiles
                _ = try QuickCropFiles.move(source, to: destination)
                return list
            }
            DispatchQueue.main.async {
                guard let self, self.fileListGeneration == generation else { return }
                self.moveBusy = false
                switch result {
                case .success(let list):
                    let removedIndex = list.firstIndex(of: source) ?? self.index
                    self.files = list.filter { $0 != source }
                    self.preferences.forgetImage(ifMatching: source)
                    self.clearImage()
                    self.index = min(removedIndex, max(0, self.files.count - 1))
                    if self.files.isEmpty {
                        self.presentCurrentThumbnails()
                    } else if !self.show(self.files[self.index]) {
                        self.presentCurrentThumbnails()
                    }
                case .failure(let error):
                    self.fileListNeedsRefresh = needsList
                    self.alert("Could not move the image: \(error.localizedDescription)")
                }
                self.updateTitle()
                self.needsDisplay = true
                self.window?.makeFirstResponder(self)
            }
        }
    }

    private func presentCurrentThumbnails() {
        guard let folder = currentFolder else { showHome(); return }
        presentation = .thumbnails
        index = min(max(index, 0), max(0, files.count - 1))
        browser.display(folder: folder, images: files, size: preferences.thumbnailSize, selecting: index)
        updatePresentation()
        updateTitle()
    }

    /// The view minus the transparent title bar strip, so the image and crop handles
    /// never sit where a mouse-down would drag the window instead.
    private var imageArea: CGRect {
        var area = bounds
        area.size.height = max(0, area.height - safeAreaInsets.top)
        return area
    }

    private var baseDisplayRect: CGRect {
        guard let doc else { return .zero }
        let usable = imageArea.insetBy(dx:24, dy:24)
        let s = min(usable.width/doc.size.width, usable.height/doc.size.height)
        let w = doc.size.width*s
        let h = doc.size.height*s
        return CGRect(x:imageArea.midX-w/2, y:imageArea.midY-h/2, width:w, height:h)
    }

    private var displayRect: CGRect {
        let base = baseDisplayRect
        guard !base.isEmpty else { return .zero }
        let w = base.width * zoomScale
        let h = base.height * zoomScale
        return CGRect(
            x:imageArea.midX-w/2 + panOffset.x,
            y:imageArea.midY-h/2 + panOffset.y,
            width:w,
            height:h
        )
    }
    override func draw(_ dirtyRect: CGRect) {
        NSColor.black.setFill()
        NSBezierPath(rect: bounds).fill()
        guard presentation == .image, let doc else { return }

        NSGraphicsContext.current?.imageInterpolation = .high
        (animationImage ?? doc.image).draw(in: displayRect, from: .zero, operation: .sourceOver, fraction: 1)

        if cropMode { drawCrop() }
        drawInfoBadge(for: doc)
    }

    var imageInfoText: String? {
        guard presentation == .image, let doc else { return nil }
        if moveBusy { return "Moving…" }
        return "\(doc.url.lastPathComponent) (\(index + 1)/\(files.count))"
    }

    private func drawInfoBadge(for doc: ImageDoc) {
        guard let info = imageInfoText else { return }
        let text = NSAttributedString(string: info, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 1)
        ])
        let size = text.size()
        let padX: CGFloat = 8, padY: CGFloat = 3
        let maxWidth = max(40, bounds.width - 24)
        let width = min(ceil(size.width) + padX * 2, maxWidth)
        let badge = CGRect(x: bounds.maxX - 10 - width, y: 10, width: width, height: ceil(size.height) + padY * 2)
        NSColor(calibratedWhite: 0, alpha: 0.55).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6).fill()
        text.draw(with: CGRect(x: badge.minX + padX, y: badge.minY + padY, width: badge.width - padX * 2, height: ceil(size.height)),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    var isShowingShortcuts: Bool { !shortcutsOverlay.isHidden }

    func toggleShortcuts() {
        let show = shortcutsOverlay.isHidden
        if show && moveBusy { return }
        shortcutsOverlay.destinationPath = preferences.destinationFolder?.path
        shortcutsOverlay.isHidden = !show
        if show {
            // While the panel is open, viewer keys must not act; Esc closes the panel only.
            // Command shortcuts (⌘, etc.) still pass through to the menu.
            shortcutsKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, !self.shortcutsOverlay.isHidden, event.window === self.window else { return event }
                if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) { return event }
                if event.keyCode == 53 { self.toggleShortcuts() }
                return nil
            }
        } else if let monitor = shortcutsKeyMonitor {
            NSEvent.removeMonitor(monitor)
            shortcutsKeyMonitor = nil
        }
        shortcutsOverlay.needsDisplay = true
        window?.makeFirstResponder(self)
    }

    override func magnify(with event: NSEvent) {
        guard doc != nil else { return }
        let oldRect = displayRect
        guard oldRect.width > 0, oldRect.height > 0 else { return }

        let cropRelative: CGRect? = cropMode && !crop.isEmpty
            ? CGRect(
                x:(crop.minX-oldRect.minX)/oldRect.width,
                y:(crop.minY-oldRect.minY)/oldRect.height,
                width:crop.width/oldRect.width,
                height:crop.height/oldRect.height
            )
            : nil

        let rawPoint = convert(event.locationInWindow, from:nil)
        let anchorPoint = oldRect.contains(rawPoint)
            ? rawPoint
            : CGPoint(x:oldRect.midX, y:oldRect.midY)
        let rx = (anchorPoint.x-oldRect.minX)/oldRect.width
        let ry = (anchorPoint.y-oldRect.minY)/oldRect.height

        var newScale = zoomScale * exp(event.magnification)
        newScale = min(12.0, max(0.2, newScale))
        if abs(newScale-1.0) < 0.015 { newScale = 1.0 }

        let base = baseDisplayRect
        let newWidth = base.width * newScale
        let newHeight = base.height * newScale
        let desiredX = anchorPoint.x - rx*newWidth
        let desiredY = anchorPoint.y - ry*newHeight
        let centeredX = imageArea.midX - newWidth/2
        let centeredY = imageArea.midY - newHeight/2

        zoomScale = newScale
        panOffset = CGPoint(x:desiredX-centeredX, y:desiredY-centeredY)
        clampPanOffset()

        if let relative = cropRelative {
            let newRect = displayRect
            crop = CGRect(
                x:newRect.minX + relative.minX*newRect.width,
                y:newRect.minY + relative.minY*newRect.height,
                width:relative.width*newRect.width,
                height:relative.height*newRect.height
            )
        }

        needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        guard doc != nil, zoomScale > 1.001, !cropMode else {
            super.scrollWheel(with:event)
            return
        }

        var dx = event.scrollingDeltaX
        var dy = event.scrollingDeltaY

        if !event.hasPreciseScrollingDeltas {
            dx *= 10
            dy *= 10
        }

        panOffset.x += dx
        panOffset.y -= dy
        clampPanOffset()
        needsDisplay = true
    }

    private func clampPanOffset() {
        if zoomScale <= 1.001 {
            if abs(zoomScale-1.0) < 0.02 { zoomScale = 1.0 }
            panOffset = .zero
            return
        }

        let base = baseDisplayRect
        let scaledWidth = base.width * zoomScale
        let scaledHeight = base.height * zoomScale

        let maxX = max(0, (scaledWidth-imageArea.width)/2)
        let maxY = max(0, (scaledHeight-imageArea.height)/2)

        panOffset.x = min(max(panOffset.x, -maxX), maxX)
        panOffset.y = min(max(panOffset.y, -maxY), maxY)
    }

    private func drawCenter(_ text: String) {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        let attrs: [NSAttributedString.Key:Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: p
        ]
        let s = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: bounds.midX-s.width/2, y: bounds.midY-s.height/2), withAttributes: attrs)
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    private func isSequentialWebP(_ doc: ImageDoc) -> Bool {
        doc.frames > 1 && doc.url.pathExtension.lowercased() == "webp"
    }

    private func configureAnimation(for doc: ImageDoc) {
        animationGeneration = UUID()
        animationFrame = 0
        animationImage = doc.image
        webPFrameQueue.removeAll(keepingCapacity:true)
        webPInitialDuration = nil
        animationFrameCache = [0:doc.image]
        animationRequestedFrames = [0]

        if isSequentialWebP(doc) {
            startSequentialWebP(doc, generation:animationGeneration)
        } else {
            ensureAnimationPrefetch(doc, generation:animationGeneration)
            startAnimationIfNeeded()
        }
    }

    private func startAnimationIfNeeded() {
        stopAnimation()
        guard let doc, doc.frames > 1, !isSequentialWebP(doc) else { return }
        scheduleNextAnimationFrame()
    }

    private func startSequentialWebP(_ doc: ImageDoc, generation: UUID) {
        let path = doc.url.path
        let pixels = max(1, Int(doc.size.width * doc.size.height))
        let maxQueued = max(2, min(8, 24_000_000 / pixels))

        animationDecodeQueue.async { [weak self] in
            guard let handle = QCWebPAnimOpen(path) else { return }
            defer { QCWebPAnimClose(handle) }

            var bootstrapFrame = true
            while true {
                let state: (Bool, Int) = DispatchQueue.main.sync {
                    guard let self else { return (false, maxQueued) }
                    let active = self.animationGeneration == generation && self.doc === doc
                    return (active, self.webPFrameQueue.count)
                }
                if !state.0 { break }
                if !bootstrapFrame && state.1 >= maxQueued {
                    Thread.sleep(forTimeInterval:0.003)
                    continue
                }

                var durationMs: Int32 = 0
                guard let rawImage = QCWebPAnimCopyNextFrame(handle, &durationMs) else {
                    Thread.sleep(forTimeInterval:0.005)
                    continue
                }
                let cgImage = rawImage.takeRetainedValue()
                let duration = max(0.02, Double(durationMs) / 1000.0)

                if bootstrapFrame {
                    bootstrapFrame = false
                    DispatchQueue.main.async { [weak self] in
                        guard let self,
                              self.animationGeneration == generation,
                              self.doc === doc else { return }
                        self.webPInitialDuration = duration
                        if self.animationTimer == nil {
                            self.scheduleSequentialWebPAdvance(after:duration, doc:doc, generation:generation)
                        }
                    }
                } else {
                    DispatchQueue.main.async { [weak self] in
                        guard let self,
                              self.animationGeneration == generation,
                              self.doc === doc else { return }
                        let image = NSImage(cgImage:cgImage, size:CGSize(width:cgImage.width, height:cgImage.height))
                        self.webPFrameQueue.append(WebPQueuedFrame(image:image, duration:duration))
                        if self.animationTimer == nil, let initial = self.webPInitialDuration {
                            self.scheduleSequentialWebPAdvance(after:initial, doc:doc, generation:generation)
                        }
                    }
                }
            }
        }
    }

    private func scheduleSequentialWebPAdvance(after delay: TimeInterval, doc: ImageDoc, generation: UUID) {
        let timer = Timer(timeInterval:max(0.005, delay), repeats:false) { [weak self] _ in
            guard let self,
                  self.animationGeneration == generation,
                  self.doc === doc else { return }

            if self.webPFrameQueue.isEmpty {
                self.scheduleSequentialWebPAdvance(after:0.005, doc:doc, generation:generation)
                return
            }

            let next = self.webPFrameQueue.removeFirst()
            self.animationFrame = (self.animationFrame + 1) % max(1, doc.frames)
            self.animationImage = next.image
            self.needsDisplay = true
            self.scheduleSequentialWebPAdvance(after:next.duration, doc:doc, generation:generation)
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode:.common)
    }

    private func ensureAnimationPrefetch(_ doc: ImageDoc, generation: UUID) {
        guard doc.frames > 1 else { return }
        var targets:[Int] = []
        for offset in 1...24 {
            let i = (animationFrame + offset) % doc.frames
            if animationFrameCache[i] == nil && !animationRequestedFrames.contains(i) {
                animationRequestedFrames.insert(i)
                targets.append(i)
            }
        }
        guard !targets.isEmpty else { return }

        let source = doc.source
        animationDecodeQueue.async { [weak self] in
            let options:[CFString:Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1100
            ]
            for i in targets {
                guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, i, options as CFDictionary) ??
                                  CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
                let image = NSImage(cgImage:thumb, size:CGSize(width:thumb.width,height:thumb.height))
                DispatchQueue.main.async {
                    guard let self, self.animationGeneration == generation else { return }
                    self.animationFrameCache[i] = image
                }
            }
        }
    }

    private func trimAnimationCache(_ doc: ImageDoc) {
        guard animationFrameCache.count > 36 else { return }
        var keep:Set<Int> = [0, animationFrame]
        for offset in -4...24 {
            let i = (animationFrame + offset + doc.frames) % doc.frames
            keep.insert(i)
        }
        for key in animationFrameCache.keys where !keep.contains(key) {
            animationFrameCache.removeValue(forKey:key)
            animationRequestedFrames.remove(key)
        }
    }

    private func scheduleNextAnimationFrame() {
        guard let doc, doc.frames > 1 else { return }
        let delay = doc.frameDurations[min(animationFrame, doc.frameDurations.count-1)]
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, let active = self.doc, active === doc else { return }
            let next = (self.animationFrame + 1) % active.frames
            if let image = self.animationFrameCache[next] {
                self.animationFrame = next
                self.animationImage = image
                self.trimAnimationCache(active)
                self.ensureAnimationPrefetch(active, generation:self.animationGeneration)
                self.needsDisplay = true
                self.scheduleNextAnimationFrame()
            } else {
                self.ensureAnimationPrefetch(active, generation:self.animationGeneration)
                let retry = Timer(timeInterval: 0.01, repeats: false) { [weak self] _ in
                    self?.scheduleNextAnimationFrame()
                }
                self.animationTimer = retry
                RunLoop.main.add(retry, forMode:.common)
            }
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode:.common)
    }

    private func fill(_ r: CGRect, _ color: NSColor) {
        guard !r.isEmpty, r.width > 0, r.height > 0 else { return }
        color.setFill()
        NSBezierPath(rect: r).fill()
    }

    private func drawCrop() {
        let d = displayRect
        let r = crop.intersection(d)
        let shade = NSColor(calibratedWhite: 0, alpha: 0.5)
        if r.isEmpty {
            fill(d, shade)
        } else {
            fill(CGRect(x:d.minX,y:d.minY,width:d.width,height:max(0,r.minY-d.minY)), shade)
            fill(CGRect(x:d.minX,y:r.maxY,width:d.width,height:max(0,d.maxY-r.maxY)), shade)
            fill(CGRect(x:d.minX,y:r.minY,width:max(0,r.minX-d.minX),height:r.height), shade)
            fill(CGRect(x:r.maxX,y:r.minY,width:max(0,d.maxX-r.maxX),height:r.height), shade)
            NSColor.black.setStroke()
            let border = NSBezierPath(rect: r)
            border.lineWidth = 1
            border.stroke()

            NSColor.black.setFill()
            let points = [
                CGPoint(x:r.minX,y:r.minY), CGPoint(x:r.midX,y:r.minY), CGPoint(x:r.maxX,y:r.minY),
                CGPoint(x:r.minX,y:r.midY), CGPoint(x:r.maxX,y:r.midY),
                CGPoint(x:r.minX,y:r.maxY), CGPoint(x:r.midX,y:r.maxY), CGPoint(x:r.maxX,y:r.maxY)
            ]
            for p in points {
                NSBezierPath(roundedRect: CGRect(x:p.x-4,y:p.y-4,width:8,height:8), xRadius:2, yRadius:2).fill()
            }
        }
    }

    func startCrop() {
        guard canEditImage else { return }
        zoomScale = 1.0
        panOffset = .zero
        cropMode = true
        crop = displayRect
        updateTitle()
        needsDisplay = true
    }

    func cancelCrop() {
        guard cropMode else { return }
        cropMode = false
        crop = .zero
        dragMode = .none
        updateTitle()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if presentation == .image { window?.makeFirstResponder(self) }
        guard cropMode else { return }
        let p = convert(event.locationInWindow, from: nil)
        let d = displayRect
        let mode = hitMode(at: p)
        guard mode != .fresh || d.contains(p) else { return }
        anchor = p
        original = crop
        dragMode = mode
        if dragMode == .fresh { crop = CGRect(origin: p, size: .zero) }
    }

    override func mouseDragged(with event: NSEvent) {
        guard cropMode, dragMode != .none else { return }
        let d = displayRect
        let raw = convert(event.locationInWindow, from: nil)
        let p = CGPoint(x:min(max(raw.x,d.minX),d.maxX), y:min(max(raw.y,d.minY),d.maxY))

        if dragMode == .fresh {
            crop = CGRect(x:min(anchor.x,p.x), y:min(anchor.y,p.y), width:abs(p.x-anchor.x), height:abs(p.y-anchor.y)).intersection(d)
        } else if dragMode == .move {
            var r = original.offsetBy(dx: p.x-anchor.x, dy: p.y-anchor.y)
            if r.minX < d.minX { r.origin.x = d.minX }
            if r.maxX > d.maxX { r.origin.x = d.maxX-r.width }
            if r.minY < d.minY { r.origin.y = d.minY }
            if r.maxY > d.maxY { r.origin.y = d.maxY-r.height }
            crop = r
        } else {
            crop = resized(from: original, to: p, mode: dragMode, within: d)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) { dragMode = .none }

    private func hitMode(at p: CGPoint) -> DragMode {
        guard !crop.isEmpty else { return .fresh }
        let radius = Self.cropHitRadius
        let corners: [(DragMode, CGPoint)] = [
            (.bottomLeft, CGPoint(x: crop.minX, y: crop.minY)),
            (.bottomRight, CGPoint(x: crop.maxX, y: crop.minY)),
            (.topLeft, CGPoint(x: crop.minX, y: crop.maxY)),
            (.topRight, CGPoint(x: crop.maxX, y: crop.maxY))
        ]
        if let corner = corners
            .filter({ abs(p.x - $0.1.x) <= radius && abs(p.y - $0.1.y) <= radius })
            .min(by: {
                hypot(p.x - $0.1.x, p.y - $0.1.y) < hypot(p.x - $1.1.x, p.y - $1.1.y)
            }) {
            return corner.0
        }

        if abs(p.x - crop.minX) <= radius && p.y >= crop.minY && p.y <= crop.maxY { return .left }
        if abs(p.x - crop.maxX) <= radius && p.y >= crop.minY && p.y <= crop.maxY { return .right }
        if abs(p.y - crop.minY) <= radius && p.x >= crop.minX && p.x <= crop.maxX { return .bottom }
        if abs(p.y - crop.maxY) <= radius && p.x >= crop.minX && p.x <= crop.maxX { return .top }
        if crop.contains(p) { return .move }
        return .fresh
    }

    private func resized(from r: CGRect, to p: CGPoint, mode: DragMode, within d: CGRect) -> CGRect {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        switch mode {
        case .left, .topLeft, .bottomLeft: minX = p.x
        default: break
        }
        switch mode {
        case .right, .topRight, .bottomRight: maxX = p.x
        default: break
        }
        switch mode {
        case .bottom, .bottomLeft, .bottomRight: minY = p.y
        default: break
        }
        switch mode {
        case .top, .topLeft, .topRight: maxY = p.y
        default: break
        }

        let result = CGRect(
            x:min(minX,maxX),
            y:min(minY,maxY),
            width:abs(maxX-minX),
            height:abs(maxY-minY)
        ).intersection(d)
        return result.width >= 4 && result.height >= 4 ? result : r
    }
    func applyCrop() {
        guard cropMode, let doc else { return }
        let d = displayRect
        let r = crop.intersection(d)
        guard r.width >= 4, r.height >= 4 else {
            alert("Drag a crop area first.")
            return
        }

        let sx = doc.size.width / d.width
        let sy = doc.size.height / d.height
        let x = Int(round((r.minX-d.minX)*sx))
        let yBottom = Int(round((r.minY-d.minY)*sy))
        let w = max(1, min(Int(round(r.width*sx)), Int(doc.size.width)-x))
        let h = max(1, min(Int(round(r.height*sy)), Int(doc.size.height)-yBottom))
        let yTop = max(0, Int(doc.size.height)-yBottom-h)

        guard let preview = doc.cg.cropping(to: CGRect(x:x,y:yTop,width:w,height:h)) else {
            alert("Crop failed: could not create the cropped image.")
            return
        }

        // Show the result immediately; encoding and writing the file happen in the background.
        let url = doc.url
        let ext = url.pathExtension.lowercased()
        let animated = doc.fileFrames > 1
        let previewDoc = ImageDoc(cropPreview: preview, of: doc)
        stopAnimation()
        self.doc = previewDoc
        cropMode = false
        crop = .zero
        dragMode = .none
        zoomScale = 1.0
        panOffset = .zero
        configureAnimation(for: previewDoc)
        updateTitle()
        needsDisplay = true

        pendingCropWrites[url, default: 0] += 1
        cropWriteQueue.async { [weak self] in
            guard let self else { return }
            let result = Result { () throws -> Void in
                if ext == "webp" {
                    if animated { try self.cropAnimatedWebP(url, x:x, y:yTop, w:w, h:h) }
                    else { try self.cropStaticWebP(url, x:x, y:yTop, w:w, h:h) }
                } else if ext == "gif" && animated {
                    try self.cropAnimatedGIF(url, x:x, y:yTop, w:w, h:h)
                } else {
                    try self.saveStill(preview, to: url)
                }
            }
            DispatchQueue.main.async { self.finishCropWrite(url, animated: animated, result: result) }
        }
    }

    private func finishCropWrite(_ url: URL, animated: Bool, result: Result<Void, Error>) {
        let remaining = (pendingCropWrites[url] ?? 1) - 1
        if remaining > 0 { pendingCropWrites[url] = remaining } else { pendingCropWrites.removeValue(forKey: url) }
        let isCurrent = presentation == .image && doc?.url == url && !cropMode
        switch result {
        case .success:
            // Animated files: swap the still preview for the real animation once all writes landed.
            guard animated, remaining == 0, isCurrent, let refreshed = try? ImageDoc(url) else { return }
            doc = refreshed
            configureAnimation(for: refreshed)
            needsDisplay = true
        case .failure(let error):
            if remaining == 0, isCurrent, let original = try? ImageDoc(url) {
                stopAnimation()
                doc = original
                configureAnimation(for: original)
                updateTitle()
                needsDisplay = true
            }
            alert("Crop failed: \(error.localizedDescription)")
        }
    }

    private func saveStill(_ image: CGImage, to url: URL) throws {
        let ext = url.pathExtension.lowercased()
        let temp = url.deletingLastPathComponent().appendingPathComponent(".quickcrop-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: temp) }

        let type: CFString
        var props: CFDictionary? = nil
        switch ext {
        case "jpg","jpeg":
            type = UTType.jpeg.identifier as CFString
            props = [kCGImageDestinationLossyCompressionQuality:0.95] as CFDictionary
        case "png":
            type = UTType.png.identifier as CFString
        case "gif":
            type = UTType.gif.identifier as CFString
        case "webp":
            type = UTType.webP.identifier as CFString
        default:
            throw QCError("Unsupported format.")
        }

        if let dest = CGImageDestinationCreateWithURL(temp as CFURL, type, 1, nil) {
            CGImageDestinationAddImage(dest, image, props)
            if CGImageDestinationFinalize(dest) {
                try replace(url, with: temp)
                return
            }
        }

        if ext == "webp" {
            let png = temp.deletingPathExtension().appendingPathExtension("png")
            defer { try? FileManager.default.removeItem(at: png) }
            guard let dest = CGImageDestinationCreateWithURL(png as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw QCError("Could not create the temporary PNG.")
            }
            CGImageDestinationAddImage(dest, image, nil)
            guard CGImageDestinationFinalize(dest) else { throw QCError("Could not encode the temporary PNG.") }
            try run("/opt/homebrew/bin/cwebp", ["-quiet","-q","95",png.path,"-o",temp.path])
            try replace(url, with: temp)
            return
        }
        throw QCError("Could not encode \(ext.uppercased()).")
    }

    private func cropAnimatedGIF(_ url: URL, x:Int, y:Int, w:Int, h:Int) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw QCError("Could not read the animated GIF.")
        }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { throw QCError("The GIF does not have multiple frames.") }

        var loop = 0
        if let global = CGImageSourceCopyProperties(source, nil) as? [CFString:Any],
           let gif = global[kCGImagePropertyGIFDictionary] as? [CFString:Any],
           let value = gif[kCGImagePropertyGIFLoopCount] as? NSNumber {
            loop = value.intValue
        }

        let temp = url.deletingLastPathComponent().appendingPathComponent(".quickcrop-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let dest = CGImageDestinationCreateWithURL(temp as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw QCError("Could not create the output GIF.")
        }

        let globalProps = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: loop
            ] as CFDictionary
        ] as CFDictionary
        CGImageDestinationSetProperties(dest, globalProps)

        for i in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(source, i, nil),
                  let cut = frame.cropping(to:CGRect(x:x,y:y,width:w,height:h)) else {
                throw QCError("Could not crop GIF frame \(i+1).")
            }

            var delay:Double = 0.1
            if let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString:Any],
               let gif = props[kCGImagePropertyGIFDictionary] as? [CFString:Any] {
                if let v = gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber { delay = v.doubleValue }
                else if let v = gif[kCGImagePropertyGIFDelayTime] as? NSNumber { delay = v.doubleValue }
            }
            let frameProps = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: max(0.02,delay),
                    kCGImagePropertyGIFUnclampedDelayTime: max(0.02,delay)
                ] as CFDictionary
            ] as CFDictionary
            CGImageDestinationAddImage(dest, cut, frameProps)
        }

        guard CGImageDestinationFinalize(dest),
              let check = CGImageSourceCreateWithURL(temp as CFURL, nil),
              CGImageSourceGetCount(check) == count,
              let first = CGImageSourceCreateImageAtIndex(check, 0, nil),
              first.width == w, first.height == h else {
            throw QCError("Verification of the cropped animated GIF failed.")
        }
        try replace(url, with:temp)
    }

    private func cropStaticWebP(_ url: URL, x:Int, y:Int, w:Int, h:Int) throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/cwebp") else {
            throw QCError("Cropping WebP requires cwebp.")
        }
        let temp = url.deletingLastPathComponent().appendingPathComponent(".quickcrop-\(UUID().uuidString).webp")
        defer { try? FileManager.default.removeItem(at: temp) }
        try run("/opt/homebrew/bin/cwebp", [
            "-quiet","-q","95",
            "-crop","\(x)","\(y)","\(w)","\(h)",
            url.path,"-o",temp.path
        ])
        guard let check = CGImageSourceCreateWithURL(temp as CFURL, nil),
              let first = CGImageSourceCreateImageAtIndex(check, 0, nil),
              first.width == w, first.height == h else {
            throw QCError("Verification of the cropped WebP failed.")
        }
        try replace(url, with: temp)
    }

    private func cropAnimatedWebP(_ url: URL, x:Int, y:Int, w:Int, h:Int) throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/img2webp") else {
            throw QCError("Cropping animated WebP requires img2webp.")
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw QCError("Could not read the animated WebP.")
        }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { throw QCError("The WebP does not have multiple frames.") }

        var loop = 0
        if let global = CGImageSourceCopyProperties(source, nil) as? [String:Any],
           let webp = global["{WebP}"] as? [String:Any],
           let value = webp["LoopCount"] as? NSNumber {
            loop = value.intValue
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("quickcrop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var frameURLs:[URL] = []
        var durations:[Int] = []
        for i in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(source, i, nil),
                  let cut = frame.cropping(to: CGRect(x:x,y:y,width:w,height:h)) else {
                throw QCError("Could not crop frame \(i+1).")
            }
            let frameURL = dir.appendingPathComponent(String(format:"frame-%06d.png", i+1))
            guard let dest = CGImageDestinationCreateWithURL(frameURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw QCError("Could not create the PNG frame.")
            }
            CGImageDestinationAddImage(dest, cut, nil)
            guard CGImageDestinationFinalize(dest) else { throw QCError("Could not encode the PNG frame.") }
            frameURLs.append(frameURL)

            var delay = 0.1
            if let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String:Any],
               let webp = props["{WebP}"] as? [String:Any] {
                if let v = webp["UnclampedDelayTime"] as? NSNumber { delay = v.doubleValue }
                else if let v = webp["DelayTime"] as? NSNumber { delay = v.doubleValue }
            }
            durations.append(max(10, Int(round(delay*1000))))
        }

        let temp = url.deletingLastPathComponent().appendingPathComponent(".quickcrop-\(UUID().uuidString).webp")
        defer { try? FileManager.default.removeItem(at: temp) }
        var args = ["-loop","\(loop)","-mixed"]
        for i in 0..<frameURLs.count {
            args += ["-d","\(durations[i])","-lossy","-q","95",frameURLs[i].path]
        }
        args += ["-o",temp.path]
        try run("/opt/homebrew/bin/img2webp", args)

        guard let check = CGImageSourceCreateWithURL(temp as CFURL, nil),
              CGImageSourceGetCount(check) == count,
              let first = CGImageSourceCreateImageAtIndex(check, 0, nil),
              first.width == w, first.height == h else {
            throw QCError("Verification of the cropped animated WebP failed.")
        }
        try replace(url, with: temp)
    }

    private func run(_ exe: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let data = err.fileHandleForReading.readDataToEndOfFile()
            throw QCError(String(data:data,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines) ?? "Encoder error.")
        }
    }

    private func replace(_ original: URL, with temp: URL) throws {
        _ = try FileManager.default.replaceItemAt(original, withItemAt: temp, backupItemName: nil, options: [])
    }

    private func trashSelectedThumbnail() {
        guard !moveBusy, files.indices.contains(index) else { return }
        let url = files[index]
        let removedIndex = index
        fileListGeneration = UUID()
        fileListNeedsRefresh = false
        preferences.forgetImage(ifMatching: url)
        files.remove(at: removedIndex)
        index = min(removedIndex, max(0, files.count - 1))
        browser.remove(at: removedIndex, select: files.isEmpty ? nil : index)
        trashPending.append(TrashRequest(url:url, removedIndex:removedIndex))
        processNextTrashRequest()
    }

    private func moveThumbnailSelection(_ keyCode: UInt16) {
        guard presentation == .thumbnails, !files.isEmpty else { return }
        let cols = browser.columnCount
        let last = files.count - 1
        var target = index
        switch keyCode {
        case 123: target -= 1
        case 124: target += 1
        case 126: target -= cols
        default:
            target += cols
            if target > last, index / cols < last / cols { target = last }
        }
        guard (0...last).contains(target), target != index else { return }
        index = target
        browser.select(index)
    }

    func trashCurrent() {
        if presentation == .thumbnails { trashSelectedThumbnail(); return }
        guard canEditImage, let url = doc?.url, !files.isEmpty else { return }
        let removedIndex = index

        fileListGeneration = UUID()
        fileListNeedsRefresh = false
        preferences.forgetImage(ifMatching: url)

        files.remove(at: removedIndex)
        if files.isEmpty {
            clearImage()
            presentCurrentThumbnails()
        } else {
            index = min(removedIndex, files.count-1)
            show(files[index])
        }

        trashPending.append(TrashRequest(url:url, removedIndex:removedIndex))
        processNextTrashRequest()
    }

    private func processNextTrashRequest() {
        guard !trashBusy, let request = trashPending.first else { return }
        trashBusy = true
        let cropWrites = cropWriteQueue

        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            cropWrites.sync {}   // finish any crop still being written before trashing
            var failure: Error?
            do {
                try FileManager.default.trashItem(at:request.url, resultingItemURL:nil)
            } catch {
                failure = error
            }

            DispatchQueue.main.async {
                guard let self else { return }

                if !self.trashPending.isEmpty {
                    self.trashPending.removeFirst()
                }
                self.trashBusy = false

                if let failure {
                    let restoreIndex = min(request.removedIndex, self.files.count)
                    self.files.insert(request.url, at:restoreIndex)
                    if restoreIndex <= self.index { self.index += 1 }
                    if self.presentation == .thumbnails { self.presentCurrentThumbnails() }
                    if self.doc == nil { self.preferences.remember(image: request.url) }
                    self.alert("Could not move to Trash: \(failure.localizedDescription)")
                }

                self.hostWindow?.makeFirstResponder(self)
                self.processNextTrashRequest()
            }
        }
    }

    func next() {
        guard canEditImage, !files.isEmpty else { return }
        let candidate = (index+1) % files.count
        if show(files[candidate]) { index = candidate; browser.focus(candidate); updateTitle() }
    }

    func previous() {
        guard canEditImage, !files.isEmpty else { return }
        let candidate = (index-1+files.count) % files.count
        if show(files[candidate]) { index = candidate; browser.focus(candidate); updateTitle() }
    }
    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command)
        if cmd && event.keyCode == 43 { toggleShortcuts(); return }  // Cmd+,
        if isShowingShortcuts {
            if event.keyCode == 53 { toggleShortcuts() }              // Esc closes the overlay only
            return
        }
        if cmd && event.keyCode == 27 { resizeThumbnails(by: -32); return }
        if cmd && event.keyCode == 24 { resizeThumbnails(by: 32); return }
        if cmd && event.keyCode == 40 { startCrop(); return }
        if cmd && event.keyCode == 51 { trashCurrent(); return }    // Cmd+Delete
        if !cmd && event.keyCode == 51 { trashCurrent(); return }   // Delete/Backspace
        if !cmd && event.keyCode == 44 { trashCurrent(); return }   // /
        if !cmd && event.keyCode == 8 { startCrop(); return }       // C
        if !cmd && event.keyCode == 9 { trashCurrent(); return }    // V
        if presentation == .thumbnails, (123...126).contains(event.keyCode) {
            moveThumbnailSelection(event.keyCode); return
        }
        if !cmd && event.keyCode == 49 {                                       // Space
            guard !event.isARepeat else { return }
            if presentation == .thumbnails, files.indices.contains(index) {
                if show(files[index]) { updateTitle() }
                return
            }
            if presentation == .image, !cropMode, !moveBusy { showThumbnails(); return }
        }
        if event.keyCode == 123 || event.keyCode == 126 { previous(); return } // Left / Up
        if event.keyCode == 124 || event.keyCode == 125 { next(); return }     // Right / Down
        if event.keyCode == 53 {
            if cropMode { cancelCrop() }
            else if presentation == .image { showThumbnails() }
            else if presentation == .thumbnails { showHome() }
            return
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            guard !event.isARepeat, !moveBusy else { return }
            if cropMode { applyCrop() }
            else { moveCurrent() }
            return
        }
        super.keyDown(with: event)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses:[NSURL.self],options:nil) as? [URL],
              !urls.isEmpty else { return false }
        if urls.count > 1 { openList(urls) }
        else if let first = urls.first { open(first) }
        return true
    }

    private func updateTitle() {
        needsDisplay = true
        if moveBusy { hostWindow?.title = "QuickCrop — Moving…" }
        else if presentation == .image, let doc {
            hostWindow?.title = "QuickCrop — \(doc.url.lastPathComponent) (\(index + 1)/\(files.count))\(cropMode ? " — Crop" : "")"
        } else if presentation == .thumbnails, let folder = currentFolder {
            hostWindow?.title = "QuickCrop — \(folder.lastPathComponent) — Thumbnails"
        } else { hostWindow?.title = "QuickCrop" }
    }

    private func alert(_ message: String) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "QuickCrop"
        a.informativeText = message
        a.runModal()
    }
}

final class QuickCropShortcutsOverlay: NSView {
    typealias Group = (title: String, rows: [(keys: String, action: String)])

    static let groups: [Group] = [
        ("General", [
            ("⌘,", "Settings & shortcuts"),
            ("⌘O", "Open image"),
            ("⇧⌘O", "Open folder"),
            ("⌘G", "Show thumbnails"),
            ("⇧⌘H", "Home"),
            ("⌘Q", "Quit")
        ]),
        ("Viewer", [
            ("← / ↑", "Previous image"),
            ("→ / ↓", "Next image"),
            ("Enter", "Move to destination, open next"),
            ("Space / Esc", "Back to thumbnails"),
            ("C / ⌘K", "Start crop"),
            ("Delete / ⌘Delete", "Move to Trash"),
            ("V or /", "Move to Trash"),
            ("Pinch / scroll", "Zoom / pan when zoomed")
        ]),
        ("Thumbnails", [
            ("← ↑ → ↓", "Move selection"),
            ("Space", "Open selected image"),
            ("Delete / ⌘Delete", "Move selected to Trash"),
            ("V or /", "Move selected to Trash"),
            ("⌘− / ⌘=", "Smaller / larger thumbnails"),
            ("Esc", "Home")
        ]),
        ("Crop", [
            ("Drag", "Draw, move or resize the crop"),
            ("Enter", "Apply crop"),
            ("Esc", "Cancel crop")
        ])
    ]

    var onClose: (() -> Void)?
    var onChooseDestination: (() -> Void)?
    var destinationPath: String? { didSet { needsDisplay = true } }

    private let chooseButton = NSButton(title: "Choose Folder…", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        chooseButton.bezelStyle = .rounded
        chooseButton.target = self
        chooseButton.action = #selector(chooseAction)
        addSubview(chooseButton)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func chooseAction() { onChooseDestination?() }

    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) {
        if !layoutInfo().panel.contains(convert(event.locationInWindow, from: nil)) { onClose?() }
    }
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}

    private let pad: CGFloat = 24
    private let columnGap: CGFloat = 36
    private let rowHeight: CGFloat = 20
    private let headerHeight: CGFloat = 24
    private let groupGap: CGFloat = 12
    private let keyGap: CGFloat = 14
    private let titleGap: CGFloat = 14
    private let settingsHeight: CGFloat = 24 + 20 + 18 + 8 + 28
    private let sectionGap: CGFloat = 20

    private var titleAttrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.white]
    }
    private var headerAttrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor(calibratedWhite: 0.6, alpha: 1)]
    }
    private var keyAttrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
    }
    private var actionAttrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(calibratedWhite: 0.82, alpha: 1)]
    }
    private var noteAttrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(calibratedWhite: 0.6, alpha: 1)]
    }

    private var columns: [[Group]] { [[Self.groups[0], Self.groups[1]], [Self.groups[2], Self.groups[3]]] }
    private let title = "Settings & Shortcuts" as NSString

    private func height(of column: [Group]) -> CGFloat {
        column.reduce(0) { $0 + headerHeight + CGFloat($1.rows.count) * rowHeight } + CGFloat(max(0, column.count - 1)) * groupGap
    }

    private func widths(of column: [Group]) -> (key: CGFloat, action: CGFloat) {
        let rows = column.flatMap { $0.rows }
        let key = rows.map { ceil(($0.keys as NSString).size(withAttributes: keyAttrs).width) }.max() ?? 0
        let action = rows.map { ceil(($0.action as NSString).size(withAttributes: actionAttrs).width) }.max() ?? 0
        return (key, action)
    }

    private func layoutInfo() -> (panel: CGRect, settingsTop: CGFloat, shortcutsTop: CGFloat, titleHeight: CGFloat) {
        let titleHeight = ceil(title.size(withAttributes: titleAttrs).height)
        let colWidths = columns.map { widths(of: $0) }
        let contentWidth = colWidths.reduce(0) { $0 + $1.key + keyGap + $1.action } + columnGap * CGFloat(columns.count - 1)
        let shortcutsHeight = columns.map { height(of: $0) }.max() ?? 0
        let panelWidth = contentWidth + pad * 2
        let panelHeight = pad + titleHeight + titleGap + settingsHeight + sectionGap + shortcutsHeight + pad
        let panel = CGRect(x: round(bounds.midX - panelWidth / 2), y: max(8, round(bounds.midY - panelHeight / 2)),
                           width: panelWidth, height: panelHeight)
        let settingsTop = panel.minY + pad + titleHeight + titleGap
        return (panel, settingsTop, settingsTop + settingsHeight + sectionGap, titleHeight)
    }

    override func layout() {
        super.layout()
        let info = layoutInfo()
        chooseButton.sizeToFit()
        chooseButton.frame.origin = CGPoint(x: info.panel.minX + pad - 6, y: info.settingsTop + 24 + 20 + 18 + 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        let info = layoutInfo()
        let panel = info.panel

        NSColor(calibratedWhite: 0.08, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: panel, xRadius: 12, yRadius: 12).fill()
        NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
        let border = NSBezierPath(roundedRect: panel.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        border.lineWidth = 1
        border.stroke()

        let titleWidth = title.size(withAttributes: titleAttrs).width
        title.draw(at: CGPoint(x: panel.midX - titleWidth / 2, y: panel.minY + pad), withAttributes: titleAttrs)

        // Settings
        let left = panel.minX + pad
        let innerWidth = panel.width - pad * 2
        var y = info.settingsTop
        ("DESTINATION FOLDER" as NSString).draw(at: CGPoint(x: left, y: y + 4), withAttributes: headerAttrs)
        y += 24
        let pathStyle = NSMutableParagraphStyle()
        pathStyle.lineBreakMode = .byTruncatingMiddle
        var pathAttrs = keyAttrs
        pathAttrs[.paragraphStyle] = pathStyle
        ((destinationPath ?? "No folder selected") as NSString)
            .draw(in: CGRect(x: left, y: y + 2, width: innerWidth, height: rowHeight), withAttributes: pathAttrs)
        y += 20
        ("Enter moves the current image here and opens the next one." as NSString)
            .draw(at: CGPoint(x: left, y: y), withAttributes: noteAttrs)

        // Divider
        let dividerY = info.shortcutsTop - sectionGap / 2
        NSColor(calibratedWhite: 1, alpha: 0.1).setFill()
        NSBezierPath(rect: CGRect(x: left, y: dividerY, width: innerWidth, height: 1)).fill()

        // Shortcuts
        var x = left
        for (column, w) in zip(columns, columns.map { widths(of: $0) }) {
            var y = info.shortcutsTop
            for (i, group) in column.enumerated() {
                if i > 0 { y += groupGap }
                (group.title.uppercased() as NSString).draw(at: CGPoint(x: x, y: y + 4), withAttributes: headerAttrs)
                y += headerHeight
                for row in group.rows {
                    let keySize = (row.keys as NSString).size(withAttributes: keyAttrs)
                    (row.keys as NSString).draw(at: CGPoint(x: x + w.key - keySize.width, y: y + 2), withAttributes: keyAttrs)
                    (row.action as NSString).draw(at: CGPoint(x: x + w.key + keyGap, y: y + 2), withAttributes: actionAttrs)
                    y += rowHeight
                }
            }
            x += w.key + keyGap + w.action + columnGap
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var window: NSWindow!
    private var viewer: Viewer!
    private var pending: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        viewer = Viewer(frame:CGRect(x:0,y:0,width:1100,height:760))
        window = NSWindow(
            contentRect:CGRect(x:0,y:0,width:1100,height:760),
            styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],
            backing:.buffered,
            defer:false
        )
        window.minSize = NSSize(width:520,height:360)
        if let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            // Open large: about 90% of the usable screen, centered.
            let size = NSSize(width: max(520, round(visible.width * 0.9)), height: max(360, round(visible.height * 0.9)))
            window.setFrame(CGRect(x: round(visible.midX - size.width / 2), y: round(visible.midY - size.height / 2),
                                   width: size.width, height: size.height), display: false)
        } else {
            window.center()
        }
        window.contentView = viewer
        window.title = "QuickCrop"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        viewer.hostWindow = window
        buildMenu()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
        window.makeFirstResponder(viewer)

        if pending.count > 1 {
            viewer.openList(pending)
            pending.removeAll()
        } else if let first = pending.first {
            viewer.open(first)
            pending.removeAll()
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath:$0) }
        if viewer == nil {
            pending = urls
        } else if urls.count > 1 {
            viewer.openList(urls)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps:true)
        } else if let first = urls.first {
            viewer.open(first)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps:true)
        }
        sender.reply(toOpenOrPrint:.success)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle:"About QuickCrop", action:#selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent:"")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle:"Settings…", action:#selector(settingsAction), keyEquivalent:",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"Quit QuickCrop", action:#selector(NSApplication.terminate(_:)), keyEquivalent:"q")

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title:"File")
        fileItem.submenu = fileMenu
        let open = fileMenu.addItem(withTitle:"Open Image…", action:#selector(openPanel), keyEquivalent:"o")
        open.target = self
        let openFolder = fileMenu.addItem(withTitle:"Open Folder…", action:#selector(openFolderAction), keyEquivalent:"o")
        openFolder.keyEquivalentModifierMask = [.command, .shift]
        openFolder.target = self
        fileMenu.addItem(.separator())
        let recentFolder = fileMenu.addItem(withTitle:"Open Recent Folder", action:#selector(recentFolderAction), keyEquivalent:"")
        recentFolder.target = self
        let recentImage = fileMenu.addItem(withTitle:"Open Recent Image", action:#selector(recentImageAction), keyEquivalent:"")
        recentImage.target = self

        let viewItem = NSMenuItem()
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu
        let home = viewMenu.addItem(withTitle:"Home", action:#selector(homeAction), keyEquivalent:"h")
        home.keyEquivalentModifierMask = [.command, .shift]
        home.target = self
        let thumbnails = viewMenu.addItem(withTitle:"Show Thumbnails", action:#selector(thumbnailsAction), keyEquivalent:"g")
        thumbnails.target = self
        viewMenu.addItem(.separator())
        let smaller = viewMenu.addItem(withTitle:"Smaller Thumbnails", action:#selector(smallerAction), keyEquivalent:"-")
        smaller.target = self
        let larger = viewMenu.addItem(withTitle:"Larger Thumbnails", action:#selector(largerAction), keyEquivalent:"=")
        larger.target = self

        let imageItem = NSMenuItem()
        main.addItem(imageItem)
        let imageMenu = NSMenu(title:"Image")
        imageItem.submenu = imageMenu
        let crop = imageMenu.addItem(withTitle:"Crop", action:#selector(cropAction), keyEquivalent:"")
        crop.target = self

        let move = imageMenu.addItem(withTitle:"Move to Destination", action:#selector(moveAction), keyEquivalent:"")
        move.target = self

        let trash = NSMenuItem(title:"Move to Trash", action:#selector(trashAction), keyEquivalent:"")
        trash.target = self
        imageMenu.addItem(trash)
        imageMenu.addItem(.separator())

        let prev = imageMenu.addItem(withTitle:"Previous Image", action:#selector(previousAction), keyEquivalent:"")
        prev.target = self
        let next = imageMenu.addItem(withTitle:"Next Image", action:#selector(nextAction), keyEquivalent:"")
        next.target = self

        let helpItem = NSMenuItem()
        main.addItem(helpItem)
        let helpMenu = NSMenu(title:"Help")
        helpItem.submenu = helpMenu
        let shortcuts = helpMenu.addItem(withTitle:"Keyboard Shortcuts", action:#selector(shortcutsAction), keyEquivalent:"")
        shortcuts.target = self
        NSApp.helpMenu = helpMenu
        NSApp.mainMenu = main
    }

    @objc private func openPanel() {
        viewer.chooseImage()
    }

    @objc private func settingsAction() { viewer.toggleShortcuts() }
    @objc private func openFolderAction() { viewer.chooseFolder() }
    @objc private func recentFolderAction() { viewer.openRecentFolder() }
    @objc private func recentImageAction() { viewer.openRecentImage() }
    @objc private func homeAction() { viewer.showHome() }
    @objc private func thumbnailsAction() { viewer.showThumbnails() }
    @objc private func smallerAction() { viewer.resizeThumbnails(by: -32) }
    @objc private func largerAction() { viewer.resizeThumbnails(by: 32) }
    @objc private func moveAction() { viewer.moveCurrent() }
    @objc private func cropAction() { viewer.startCrop() }
    @objc private func trashAction() { viewer.trashCurrent() }
    @objc private func previousAction() { viewer.previous() }
    @objc private func nextAction() { viewer.next() }
    @objc private func shortcutsAction() { viewer.showSettings() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(smallerAction): return viewer.canResizeThumbnails && viewer.preferences.thumbnailSize > 96
        case #selector(largerAction): return viewer.canResizeThumbnails && viewer.preferences.thumbnailSize < 320
        case #selector(moveAction): return viewer.canMoveImage
        case #selector(trashAction): return viewer.canTrash
        case #selector(cropAction), #selector(previousAction), #selector(nextAction): return viewer.canEditImage
        case #selector(recentFolderAction), #selector(thumbnailsAction): return viewer.preferences.recentFolder != nil
        case #selector(recentImageAction): return viewer.preferences.recentImage != nil
        case #selector(settingsAction):
            menuItem.state = viewer.isShowingShortcuts ? .on : .off
            return true
        default: return true
        }
    }
}

#if !QUICKCROP_TESTING
@main
struct QuickCropApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
