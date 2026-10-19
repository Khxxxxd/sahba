import AppKit

/// Ctrl wheel: things to do with files and folders, without changing them.
enum Actions {
    static func airDrop(_ urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            HUD.shared.flash(tr("AirDrop مو متاح الحين", "AirDrop isn't available right now"), failed: true)
            return
        }
        service.perform(withItems: urls)
    }

    static func copyPath(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
        HUD.shared.flash(urls.count == 1 ? tr("انتسخ المسار", "Path copied") : tr("انتسخت \(urls.count) مسارات", "\(urls.count) paths copied"))
    }

    static func move(_ urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = tr("انقل هنا", "Move Here")
        panel.message = urls.count == 1
            ? tr("وين تبي تنقل \(urls[0].lastPathComponent)؟", "Where should \(urls[0].lastPathComponent) go?")
            : tr("وين تبي تنقل \(urls.count) ملفات؟", "Where should \(urls.count) files go?")
        panel.directoryURL = urls.first?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        var moved = 0
        for url in urls {
            if url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL {
                moved += 1
                continue
            }
            let name = url.deletingPathExtension().lastPathComponent
            let dest = Output.unique(in: dir, base: name, ext: url.pathExtension)
            do {
                try FileManager.default.moveItem(at: url, to: dest)
                moved += 1
                Log.write("moved \(url.path) -> \(dest.path)")
            } catch {
                Log.write("move failed \(url.path): \(error)")
            }
        }
        HUD.shared.flash(moved == urls.count ? tr("انتقلت إلى \(dir.lastPathComponent)", "Moved to \(dir.lastPathComponent)")
                                            : tr("انتقل \(moved) من \(urls.count)", "Moved \(moved) of \(urls.count)"),
                         failed: moved < urls.count)
    }

    static func terminal(_ urls: [URL]) {
        guard let first = urls.first else { return }
        let isDir = (try? first.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let folder = isDir ? first : first.deletingLastPathComponent()
        let app = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    static func float(_ urls: [URL]) {
        FloatShelf.open(urls, near: NSEvent.mouseLocation)
    }
}

/// A small window that stays on top and holds files, so you can drag them out later.
final class FloatShelf: NSObject {
    private static var shelves: [FloatShelf] = []
    private let panel: NSPanel
    private let shelf: ShelfView

    static func open(_ urls: [URL], near point: NSPoint) {
        shelves.append(FloatShelf(urls, near: point))
    }

    private init(_ urls: [URL], near point: NSPoint) {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        shelf = ShelfView(urls: urls)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        shelf.onClose = { [weak self] in self?.close() }
        shelf.onResize = { [weak self] in self?.layout(keepingTopAt: nil) }
        layout(keepingTopAt: NSPoint(x: point.x - ShelfView.width / 2, y: point.y + 40))
        panel.orderFrontRegardless()
    }

    private func layout(keepingTopAt topLeft: NSPoint?) {
        let size = shelf.fittingSize
        let top = topLeft ?? NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        let frame = NSRect(x: top.x, y: top.y - size.height, width: size.width, height: size.height)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let glass = WheelController.glass(container.bounds, radius: 18)
        glass.autoresizingMask = [.width, .height]
        shelf.frame = container.bounds
        shelf.autoresizingMask = [.width, .height]
        container.addSubview(glass)
        container.addSubview(shelf)
        panel.contentView = container
        panel.setFrame(frame, display: true)
    }

    private func close() {
        panel.orderOut(nil)
        FloatShelf.shelves.removeAll { $0 === self }
    }
}

final class ShelfView: NSView {
    static let width: CGFloat = 250
    private static let rowHeight: CGFloat = 46, headerHeight: CGFloat = 38, maxRows = 6

    private(set) var urls: [URL]
    var onClose: (() -> Void)?
    var onResize: (() -> Void)?

    init(urls: [URL]) {
        self.urls = urls
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize {
        NSSize(width: Self.width, height: Self.headerHeight + CGFloat(min(urls.count, Self.maxRows)) * Self.rowHeight + 10)
    }

    override var isFlipped: Bool { true }

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        let title = NSTextField(labelWithString: urls.count == 1 ? tr("ملف معلّق", "1 floating file") : tr("\(urls.count) ملفات معلّقة", "\(urls.count) floating files"))
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.alignment = L10n.arabic ? .right : .left
        title.frame = NSRect(x: 40, y: 11, width: Self.width - 54, height: 16)
        addSubview(title)

        let closeImage = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: tr("سكّر", "Close"))
            ?? NSImage(named: NSImage.stopProgressFreestandingTemplateName)
        let close = NSButton(image: closeImage ?? NSImage(),
                             target: self, action: #selector(closeTapped))
        close.isBordered = false
        close.contentTintColor = .secondaryLabelColor
        close.frame = NSRect(x: 10, y: 8, width: 22, height: 22)
        addSubview(close)

        for (i, url) in urls.prefix(Self.maxRows).enumerated() {
            let tile = TileView(url: url)
            tile.frame = NSRect(x: 8, y: Self.headerHeight + CGFloat(i) * Self.rowHeight, width: Self.width - 16, height: Self.rowHeight - 4)
            addSubview(tile)
        }
        if urls.count > Self.maxRows {
            title.stringValue += tr(" (يبين أول \(Self.maxRows))", " (showing \(Self.maxRows))")
        }
    }

    @objc private func closeTapped() { onClose?() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let new = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let fresh = new.filter { !urls.contains($0) }
        guard !fresh.isEmpty else { return false }
        urls += fresh
        rebuild()
        onResize?()
        return true
    }
}

/// One file in the shelf. Drag it out to copy it anywhere.
final class TileView: NSView, NSDraggingSource {
    let url: URL
    private let icon: NSImage

    init(url: URL) {
        self.url = url
        icon = NSWorkspace.shared.icon(forFile: url.path)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        layer?.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor
        layer?.borderWidth = 1.0

        let image = NSImageView(image: icon)
        image.frame = NSRect(x: 0, y: 0, width: 34, height: 34)
        image.autoresizingMask = [.minXMargin]
        addSubview(image)
        let label = NSTextField(labelWithString: url.lastPathComponent)
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = Theme.labelPrimary
        label.alignment = L10n.arabic ? .right : .left
        addSubview(label)
        self.label = label
        self.image = image
    }

    private var label: NSTextField!
    private var image: NSImageView!
    private var trackingArea: NSTrackingArea?

    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil)
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.15).cgColor
        layer?.borderColor = Theme.accentTop.withAlphaComponent(0.45).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.08).cgColor
        layer?.borderColor = NSColor(white: 1.0, alpha: 0.12).cgColor
    }

    override func layout() {
        super.layout()
        // Icon on the reading side: right in Arabic, left in English.
        let iconX: CGFloat = L10n.arabic ? bounds.width - 40 : 8
        image.frame = NSRect(x: iconX, y: (bounds.height - 32) / 2, width: 32, height: 32)
        label.frame = NSRect(x: L10n.arabic ? 8 : 46, y: (bounds.height - 16) / 2, width: bounds.width - 54, height: 16)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(image.frame, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .generic, .link]
    }
}
