import Cocoa
import ImageIO
import CryptoKit

final class QuickCropPreferences {
    private let defaults: UserDefaults
    private let prefix = "quickcrop."

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func url(for key: String) -> URL? {
        guard let path = defaults.string(forKey: prefix + key), !path.isEmpty else { return nil }
        return QuickCropFiles.canonicalURL(URL(fileURLWithPath: path))
    }

    var destinationFolder: URL? {
        get { url(for: "destinationFolder") }
        set { defaults.set(newValue.map { QuickCropFiles.canonicalURL($0).path }, forKey: prefix + "destinationFolder") }
    }
    var recentFolder: URL? { url(for: "recentFolder") }
    var recentImage: URL? { url(for: "recentImage") }

    var thumbnailSize: CGFloat {
        get {
            let saved = defaults.double(forKey: prefix + "thumbnailSize")
            return saved > 0 ? min(320, max(96, saved)) : 160
        }
        set { defaults.set(Double(min(320, max(96, newValue))), forKey: prefix + "thumbnailSize") }
    }

    func remember(folder: URL) {
        defaults.set(QuickCropFiles.canonicalURL(folder).path, forKey: prefix + "recentFolder")
    }

    func remember(image: URL) {
        remember(folder: image.deletingLastPathComponent())
        defaults.set(QuickCropFiles.canonicalURL(image).path, forKey: prefix + "recentImage")
    }

    func forgetImage(ifMatching image: URL) {
        if recentImage == QuickCropFiles.canonicalURL(image) {
            defaults.removeObject(forKey: prefix + "recentImage")
        }
    }

    // A file can be moved or deleted outside QuickCrop between launches.
    func imageToResume() throws -> URL? {
        if let image = recentImage,
           (try? image.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            return image
        }
        guard let folder = recentImage?.deletingLastPathComponent() ?? recentFolder else { return nil }
        return try QuickCropFiles.images(in: folder).first
    }
}

enum QuickCropFileError: LocalizedError {
    case invalidDestination, sameFolder, symbolicImage, tooManyConflicts

    var errorDescription: String? {
        switch self {
        case .invalidDestination: return "The destination folder no longer exists. Please choose it again in Settings."
        case .sameFolder: return "The destination folder is the same as the current image folder. Please choose a different folder."
        case .symbolicImage: return "This image is a link to a file elsewhere. Open the original file to move it."
        case .tooManyConflicts: return "Too many files with the same name in the destination folder."
        }
    }
}

enum QuickCropFiles {
    static let extensions: Set<String> = ["webp", "jpg", "jpeg", "png", "gif"]

    static func canonicalURL(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        var directory: ObjCBool = false
        FileManager.default.fileExists(atPath: standardized.path, isDirectory: &directory)
        // Resolve folder aliases, but retain a file symlink as the selected entry.
        let resolved = directory.boolValue ? standardized.resolvingSymlinksInPath() :
            standardized.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(standardized.lastPathComponent)
        return URL(fileURLWithPath: resolved.path, isDirectory: directory.boolValue)
    }

    static func images(in folder: URL) throws -> [URL] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: canonicalURL(folder), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )
        return urls.filter {
            extensions.contains($0.pathExtension.lowercased()) &&
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.map { canonicalURL($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // FileManager refuses an existing destination. A name collision never replaces a file.
    static func move(_ source: URL, to folder: URL) throws -> URL {
        let manager = FileManager.default
        let source = canonicalURL(source)
        let destinationFolder = canonicalURL(folder)
        guard (try? source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw QuickCropFileError.symbolicImage
        }
        guard (try? destinationFolder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw QuickCropFileError.invalidDestination
        }
        guard canonicalURL(source.deletingLastPathComponent()).path != destinationFolder.path else {
            throw QuickCropFileError.sameFolder
        }
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        for suffix in 0..<10_000 {
            let name = suffix == 0 ? source.lastPathComponent : "\(stem) (\(suffix)).\(ext)"
            let destination = destinationFolder.appendingPathComponent(name)
            if manager.fileExists(atPath: destination.path) { continue }
            do {
                try manager.moveItem(at: source, to: destination)
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                // Another process may have claimed this name after the existence check.
                continue
            }
        }
        throw QuickCropFileError.tooManyConflicts
    }
}

final class QuickCropThumbnailLoader {
    private struct Entry { let key: String; let image: NSImage }
    private var entries: [URL: Entry] = [:]
    private var window: Set<URL> = []
    private let lock = NSLock()
    private static let maxEntries = 320
    private let prefetchQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.khanh.quickcrop.thumbnails.prefetch"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 3
        return queue
    }()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.khanh.quickcrop.thumbnails"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
        return queue
    }()
    /// Maximum long edge (in pixels) of a thumbnail; scales with the cell size to avoid over-decoding.
    var maxPixel = 400

    private static let diskDirectory: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = caches.appendingPathComponent("com.khanh.quickcrop/thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    init() {
        DispatchQueue.global(qos: .utility).async { Self.pruneDiskCache() }
    }

    private static func pruneDiskCache() {
        guard let directory = diskDirectory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentAccessDateKey, .contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        for file in files {
            let values = try? file.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey])
            let used = values?.contentAccessDate ?? values?.contentModificationDate ?? Date()
            if used < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    static func thumbnail(for url: URL, maxPixel: Int = 640) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func diskFile(for key: String) -> URL? {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return diskDirectory?.appendingPathComponent(digest + ".img")
    }

    /// Reads the thumbnail cached on disk; if missing, decodes the original image and caches it.
    private static func cachedThumbnail(for url: URL, key: String, maxPixel: Int) -> CGImage? {
        let file = diskFile(for: key)
        if let file, FileManager.default.fileExists(atPath: file.path),
           let source = CGImageSourceCreateWithURL(file as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
            return image
        }
        guard let image = thumbnail(for: url, maxPixel: maxPixel) else { return nil }
        if let file {
            let opaque = [CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
            let type = (opaque ? "public.jpeg" : "public.png") as CFString
            if let output = CGImageDestinationCreateWithURL(file as CFURL, type, 1, nil) {
                CGImageDestinationAddImage(output, image, opaque ? [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary : nil)
                _ = CGImageDestinationFinalize(output)
            }
        }
        return image
    }

    private static func cacheKey(for url: URL, pixel: Int) -> String {
        let metadata = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return "\(url.path)|\(metadata?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(metadata?.fileSize ?? 0)|\(pixel)"
    }

    private func cachedImage(_ url: URL, _ key: String) -> NSImage? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[url], entry.key == key else { return nil }
        return entry.image
    }

    private func store(_ url: URL, key: String, image: NSImage) {
        lock.lock(); defer { lock.unlock() }
        entries[url] = Entry(key: key, image: image)
        guard entries.count > Self.maxEntries else { return }
        for other in Array(entries.keys) where !window.contains(other) && other != url {
            entries.removeValue(forKey: other)
            if entries.count <= Self.maxEntries { break }
        }
    }

    /// Keeps only thumbnails for images in `ordered` (nearest to the selection first) and loads the missing ones in the background.
    func prefetch(_ ordered: [URL]) {
        lock.lock()
        window = Set(ordered)
        for other in Array(entries.keys) where !window.contains(other) { entries.removeValue(forKey: other) }
        lock.unlock()
        prefetchQueue.cancelAllOperations()
        let pixel = maxPixel
        for url in ordered {
            let operation = BlockOperation()
            operation.addExecutionBlock { [weak self, weak operation] in
                guard let self, operation?.isCancelled == false else { return }
                let key = Self.cacheKey(for: url, pixel: pixel)
                if self.cachedImage(url, key) != nil { return }
                guard let cg = Self.cachedThumbnail(for: url, key: key, maxPixel: pixel) else { return }
                self.store(url, key: key, image: NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)))
            }
            prefetchQueue.addOperation(operation)
        }
    }

    @discardableResult
    func load(_ url: URL, completion: @escaping (NSImage?) -> Void) -> Operation? {
        let pixel = maxPixel
        let key = Self.cacheKey(for: url, pixel: pixel)
        if let image = cachedImage(url, key) { completion(image); return nil }
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            if operation?.isCancelled == true { return }
            let cg = Self.cachedThumbnail(for: url, key: key, maxPixel: pixel)
            let image = cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            if let image { self?.store(url, key: key, image: image) }
            if operation?.isCancelled == true { return }
            DispatchQueue.main.async { completion(image) }
        }
        queue.addOperation(operation)
        return operation
    }
}

final class QuickCropWelcomeView: NSView {
    var onOpenImage: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onRecentFolder: (() -> Void)?
    var onRecentImage: (() -> Void)?
    var onSettings: (() -> Void)?

    private let folderButton = NSButton()
    private let imageButton = NSButton()
    private let destinationLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        let title = NSTextField(labelWithString: "QuickCrop")
        title.font = .systemFont(ofSize: 32, weight: .semibold)
        title.textColor = .white
        let subtitle = NSTextField(labelWithString: "Open a folder to browse your images")
        subtitle.font = .systemFont(ofSize: 15)
        subtitle.textColor = .secondaryLabelColor

        let openImage = NSButton(title: "Open Image…", target: self, action: #selector(openImageAction))
        let openFolder = NSButton(title: "Open Folder…", target: self, action: #selector(openFolderAction))
        openImage.bezelStyle = .rounded
        openFolder.bezelStyle = .rounded
        let actions = NSStackView(views: [openImage, openFolder])
        actions.orientation = .horizontal
        actions.spacing = 12

        for button in [folderButton, imageButton] {
            button.bezelStyle = .rounded
            button.alignment = .left
            button.lineBreakMode = .byTruncatingMiddle
            button.imagePosition = .imageLeading
            button.target = self
            button.heightAnchor.constraint(equalToConstant: 42).isActive = true
            button.widthAnchor.constraint(equalToConstant: 380).isActive = true
        }
        folderButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        folderButton.action = #selector(recentFolderAction)
        imageButton.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        imageButton.action = #selector(recentImageAction)
        let recents = NSStackView(views: [folderButton, imageButton])
        recents.orientation = .vertical
        recents.spacing = 10

        destinationLabel.font = .systemFont(ofSize: 12)
        destinationLabel.textColor = .secondaryLabelColor
        destinationLabel.lineBreakMode = .byTruncatingMiddle
        destinationLabel.maximumNumberOfLines = 1
        let settings = NSButton(title: "Settings…", target: self, action: #selector(settingsAction))
        settings.bezelStyle = .rounded
        let destination = NSStackView(views: [destinationLabel, settings])
        destination.orientation = .vertical
        destination.spacing = 8
        let stack = NSStackView(views: [title, subtitle, actions, recents, destination])
        stack.orientation = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
            destinationLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func refresh(_ preferences: QuickCropPreferences) {
        folderButton.title = preferences.recentFolder.map { "Recent Folder: \($0.lastPathComponent)" } ?? "No recent folder"
        folderButton.toolTip = preferences.recentFolder?.path
        folderButton.isEnabled = preferences.recentFolder != nil
        imageButton.title = preferences.recentImage.map { "Recent Image: \($0.lastPathComponent)" } ?? "No recent image"
        imageButton.toolTip = preferences.recentImage?.path
        imageButton.isEnabled = preferences.recentImage != nil
        destinationLabel.stringValue = preferences.destinationFolder.map { "Enter → \($0.lastPathComponent)" } ?? "Choose a destination folder in Settings"
        destinationLabel.toolTip = preferences.destinationFolder?.path
    }

    @objc private func openImageAction() { onOpenImage?() }
    @objc private func openFolderAction() { onOpenFolder?() }
    @objc private func recentFolderAction() { onRecentFolder?() }
    @objc private func recentImageAction() { onRecentImage?() }
    @objc private func settingsAction() { onSettings?() }
}

/// Refuses first responder so key events always go back to the Viewer.
final class QuickCropCollectionView: NSCollectionView {
    override var acceptsFirstResponder: Bool { false }
}

final class QuickCropThumbnailItem: NSCollectionViewItem {
    private let thumbnailView = NSImageView()
    private let filenameLabel = NSTextField(labelWithString: "")
    private var request = UUID()
    private var open: (() -> Void)?
    private var loading: Operation?

    override func prepareForReuse() {
        loading?.cancel()
        loading = nil
        request = UUID()
        super.prepareForReuse()
    }

    override func loadView() {
        let button = NSButton(title: "", target: self, action: #selector(openAction))
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor(calibratedWhite: 0.1, alpha: 1).cgColor
        button.layer?.cornerRadius = 8
        view = button
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        filenameLabel.font = .systemFont(ofSize: 12)
        filenameLabel.textColor = .labelColor
        filenameLabel.alignment = .center
        filenameLabel.lineBreakMode = .byTruncatingMiddle
        filenameLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(thumbnailView)
        view.addSubview(filenameLabel)
        NSLayoutConstraint.activate([
            thumbnailView.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            thumbnailView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            thumbnailView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            thumbnailView.bottomAnchor.constraint(equalTo: filenameLabel.topAnchor, constant: -8),
            filenameLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            filenameLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            filenameLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -10),
            filenameLabel.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    func setHighlighted(_ on: Bool) {
        view.layer?.borderWidth = on ? 3 : 0
        view.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    func configure(url: URL, loader: QuickCropThumbnailLoader, selected: Bool, onOpen: @escaping () -> Void) {
        setHighlighted(selected)
        let token = UUID()
        request = token
        open = onOpen
        filenameLabel.stringValue = url.lastPathComponent
        view.toolTip = url.path
        view.setAccessibilityLabel("Open \(url.lastPathComponent)")
        thumbnailView.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        loading?.cancel()
        loading = loader.load(url) { [weak self] image in
            guard let self, self.request == token else { return }
            if let image { self.thumbnailView.image = image }
        }
    }

    @objc private func openAction() { open?() }
}

final class QuickCropThumbnailBrowser: NSView, NSCollectionViewDataSource {
    var onOpen: ((URL) -> Void)?
    var onHome: (() -> Void)?
    var onChooseFolder: (() -> Void)?
    var onSmaller: (() -> Void)?
    var onLarger: (() -> Void)?

    private let collection = QuickCropCollectionView()
    private let flow = NSCollectionViewFlowLayout()
    private let loader = QuickCropThumbnailLoader()
    private let folderLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "")
    private let smallerButton = NSButton(title: "−", target: nil, action: nil)
    private let largerButton = NSButton(title: "+", target: nil, action: nil)
    private var urls: [URL] = []
    private(set) var selectedIndex: Int?
    private var focusWork: DispatchWorkItem?
    private let thumbnailIdentifier = NSUserInterfaceItemIdentifier("QuickCropThumbnail")

    override init(frame: NSRect) {
        super.init(frame: frame)
        let home = NSButton(title: "Home", target: self, action: #selector(homeAction))
        let chooseFolder = NSButton(title: "Open Folder…", target: self, action: #selector(chooseFolderAction))
        for button in [home, chooseFolder, smallerButton, largerButton] { button.bezelStyle = .rounded }
        smallerButton.target = self
        smallerButton.action = #selector(smallerAction)
        smallerButton.toolTip = "Smaller thumbnails (⌘−)"
        smallerButton.setAccessibilityLabel("Smaller thumbnails")
        largerButton.target = self
        largerButton.action = #selector(largerAction)
        largerButton.toolTip = "Larger thumbnails (⌘=)"
        largerButton.setAccessibilityLabel("Larger thumbnails")
        folderLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        countLabel.font = .systemFont(ofSize: 12)
        countLabel.textColor = .secondaryLabelColor
        let spacer = NSView()
        let header = NSStackView(views: [home, folderLabel, countLabel, spacer, smallerButton, largerButton, chooseFolder])
        header.orientation = .horizontal
        header.spacing = 12
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        flow.minimumInteritemSpacing = 12
        flow.minimumLineSpacing = 12
        flow.sectionInset = NSEdgeInsets(top: 12, left: 16, bottom: 16, right: 16)
        collection.collectionViewLayout = flow
        collection.dataSource = self
        collection.backgroundColors = [.black]
        collection.register(QuickCropThumbnailItem.self, forItemWithIdentifier: thumbnailIdentifier)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = collection
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    var columnCount: Int {
        let usable = collection.bounds.width - flow.sectionInset.left - flow.sectionInset.right
        let step = flow.itemSize.width + flow.minimumInteritemSpacing
        return max(1, Int((usable + flow.minimumInteritemSpacing) / max(step, 1)))
    }

    /// Sets the hot window: the 100 images before and after the focused image are kept in memory and loaded in the background.
    func focus(_ index: Int) {
        guard !urls.isEmpty else { return }
        focusWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.urls.isEmpty else { return }
            let center = min(max(index, 0), self.urls.count - 1)
            var ordered = [self.urls[center]]
            for distance in 1...100 {
                if center + distance < self.urls.count { ordered.append(self.urls[center + distance]) }
                if center - distance >= 0 { ordered.append(self.urls[center - distance]) }
            }
            self.loader.prefetch(ordered)
        }
        focusWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func select(_ index: Int?) {
        let old = selectedIndex
        selectedIndex = index
        if let index { focus(index) }
        if let old, old != index { (collection.item(at: IndexPath(item: old, section: 0)) as? QuickCropThumbnailItem)?.setHighlighted(false) }
        guard let index, urls.indices.contains(index) else { return }
        let path = IndexPath(item: index, section: 0)
        (collection.item(at: path) as? QuickCropThumbnailItem)?.setHighlighted(true)
        reveal(index)
    }

    private func reveal(_ index: Int) {
        collection.layoutSubtreeIfNeeded()
        guard let frame = flow.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame else { return }
        collection.scrollToVisible(frame.insetBy(dx: 0, dy: -16))
    }

    func remove(at index: Int, select newIndex: Int?) {
        guard urls.indices.contains(index) else { return }
        urls.remove(at: index)
        selectedIndex = nil
        collection.deleteItems(at: [IndexPath(item: index, section: 0)])
        countLabel.stringValue = "\(urls.count) images"
        emptyLabel.stringValue = "No images in this folder"
        emptyLabel.isHidden = !urls.isEmpty
        select(newIndex)
    }

    func display(folder: URL, images: [URL], size: CGFloat, loading: Bool = false, selecting: Int? = nil) {
        if !loading, images == urls, folderLabel.toolTip == folder.path {
            // Same list already displayed: keep the grid (and scroll position) and only change the selected cell.
            resizeThumbnails(to: size)
            let target = images.isEmpty ? nil : selecting.map { min(max($0, 0), images.count - 1) }
            if target == selectedIndex, let target { reveal(target); focus(target) } else { select(target) }
            return
        }
        folderLabel.stringValue = folder.lastPathComponent
        folderLabel.toolTip = folder.path
        countLabel.stringValue = loading ? "Loading…" : "\(images.count) images"
        urls = images
        emptyLabel.stringValue = loading ? "Loading images…" : "No images in this folder"
        emptyLabel.isHidden = !images.isEmpty
        loader.maxPixel = size <= 192 ? 400 : 640
        resizeThumbnails(to: size)
        selectedIndex = images.isEmpty ? nil : selecting.map { min(max($0, 0), images.count - 1) }
        collection.reloadData()
        focus(selectedIndex ?? 0)
        if let selectedIndex {
            layoutSubtreeIfNeeded()
            reveal(selectedIndex)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectedIndex == selectedIndex else { return }
                self.reveal(selectedIndex)
            }
        }
    }

    func resizeThumbnails(to size: CGFloat) {
        let pixel = size <= 192 ? 400 : 640
        let pixelChanged = pixel != loader.maxPixel
        loader.maxPixel = pixel
        if pixelChanged, !urls.isEmpty { collection.reloadData() }
        flow.itemSize = NSSize(width: size, height: size + 34)
        smallerButton.isEnabled = size > 96
        largerButton.isEnabled = size < 320
        flow.invalidateLayout()
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { urls.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: thumbnailIdentifier, for: indexPath) as! QuickCropThumbnailItem
        let url = urls[indexPath.item]
        item.configure(url: url, loader: loader, selected: indexPath.item == selectedIndex) { [weak self] in self?.onOpen?(url) }
        return item
    }

    @objc private func homeAction() { onHome?() }
    @objc private func chooseFolderAction() { onChooseFolder?() }
    @objc private func smallerAction() { onSmaller?() }
    @objc private func largerAction() { onLarger?() }
}
