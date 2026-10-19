import AppKit

/// The floating glass panel that pops up under the cursor and holds the wheel.
final class WheelController {
    private let panel: NSPanel
    private let wheel: WheelView
    private var generation = 0

    init() {
        let rect = NSRect(origin: .zero, size: WheelView.size)
        panel = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let container = NSView(frame: rect)
        container.wantsLayer = true
        let c = WheelView.center, r = WheelView.outerR + 10
        container.addSubview(Self.glass(NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), radius: r))
        container.addSubview(Self.glass(WheelView.pillsRect, radius: WheelView.pillsRect.height / 2))
        wheel = WheelView(frame: rect)
        container.addSubview(wheel)
        panel.contentView = container
        wheel.controller = self
    }

    /// Apple's Liquid Glass on macOS 26+, frosted blur before that.
    static func glass(_ rect: NSRect, radius: CGFloat) -> NSView {
        if #available(macOS 26.0, *) {
            let g = NSGlassEffectView(frame: rect)
            g.cornerRadius = radius
            g.tintColor = NSColor(srgbRed: 0.06, green: 0.11, blue: 0.30, alpha: 0.55)
            return g
        }
        let v = NSVisualEffectView(frame: rect)
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = radius
        v.layer?.masksToBounds = true
        return v
    }

    func show(at p: NSPoint, mode: WheelMode, files: [URL] = []) {
        generation += 1
        let size = WheelView.size, c = WheelView.center
        var frame = NSRect(x: p.x - c.x, y: p.y - c.y, width: size.width, height: size.height)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) }) {
            let s = screen.frame
            frame.origin.x = min(max(frame.minX, s.minX), s.maxX - size.width)
            frame.origin.y = min(max(frame.minY, s.minY), s.maxY - size.height)
        }
        wheel.reset(mode: mode, files: files)
        panel.setFrame(frame, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            panel.animator().alphaValue = 1
        }
        popIn()
        Log.write("shown \(mode) at \(Int(p.x)),\(Int(p.y))")
    }

    /// Springs the wheel open from its centre.
    private func popIn() {
        guard let layer = panel.contentView?.layer else { return }
        let c = WheelView.center
        var t = CATransform3DMakeTranslation(c.x, c.y, 0)
        t = CATransform3DScale(t, 0.55, 0.55, 1)
        t = CATransform3DTranslate(t, -c.x, -c.y, 0)
        let a = CASpringAnimation(keyPath: "transform")
        a.fromValue = NSValue(caTransform3D: t)
        a.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        a.damping = 15
        a.stiffness = 260
        a.mass = 0.8
        a.duration = a.settlingDuration
        layer.add(a, forKey: "pop")
    }

    func setMode(_ mode: WheelMode) {
        guard panel.isVisible else { return }
        wheel.setMode(mode)
        Log.write("mode \(mode)")
    }

    /// Waits a moment after the mouse is released so a drop on the wheel can finish first.
    func hideSoon() {
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.generation == g else { return }
            self.hide()
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        Log.write("hidden")
    }

    func perform(_ item: WheelItem, files: [URL]) {
        // After the drag has fully ended, so windows and panels can take focus.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { Runner.perform(item, files: files) }
    }
}

/// Draws the segments, the hub and the mode pills, and accepts the dropped files.
final class WheelView: NSView {
    static let outerR: CGFloat = 134
    static let innerR: CGFloat = 52
    static let side: CGFloat = 2 * (outerR + 26)
    static let pillsHeight: CGFloat = 30
    static let size = NSSize(width: side, height: side + pillsHeight + 6)
    static let center = NSPoint(x: side / 2, y: pillsHeight + 6 + side / 2)
    static let pillsRect = NSRect(x: side / 2 - 132, y: 0, width: 264, height: pillsHeight)

    weak var controller: WheelController?
    /// Snapshot mode has no glass behind it, so it paints a stand-in desktop.
    var paintsBackdrop = false

    private(set) var mode: WheelMode = .convert
    private(set) var files: [URL] = []
    private(set) var kind: FileKind?
    private var totalBytes: Int64 = 0
    private(set) var items: [WheelItem] = []

    var hovered: Int? {
        didSet {
            guard hovered != oldValue else { return }
            if hovered != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            animate()
        }
    }

    // Animation state.
    private var lift: [CGFloat] = []
    private var reveal: CGFloat = 1
    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    func reset(mode: WheelMode, files: [URL] = []) {
        self.mode = mode
        if !files.isEmpty {
            setFiles(files)
        } else {
            self.files = []
            self.kind = nil
            self.totalBytes = 0
            self.items = []
            self.lift = []
            self.hovered = nil
            self.reveal = 1
            self.needsDisplay = true
        }
    }

    func setMode(_ m: WheelMode) {
        guard m != mode else { return }
        mode = m
        reload()
    }

    /// Used by the drop target, and by the snapshot test mode with fake files.
    func setFiles(_ urls: [URL], kind: FileKind? = nil) {
        files = urls
        self.kind = kind ?? Kinds.groupKind(urls)
        totalBytes = urls.reduce(0) { $0 + Kinds.size($1) }
        reload()
    }

    private func reload() {
        items = kind.map { Catalog.items(mode, $0) } ?? []
        hovered = nil
        lift = Array(repeating: 0, count: items.count)
        reveal = 0
        animate()
        needsDisplay = true
    }

    func finishAnimations() {
        reveal = 1
        for i in lift.indices { lift[i] = hovered == i ? 1 : 0 }
    }

    private func animate() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        var moving = false
        if reveal < 1 { reveal = min(1, reveal + 1.0 / 13); moving = true }
        for i in lift.indices {
            let target: CGFloat = hovered == i ? 1 : 0
            let d = target - lift[i]
            if abs(d) > 0.01 { lift[i] += d * 0.32; moving = true } else { lift[i] = target }
        }
        needsDisplay = true
        if !moving { timer?.invalidate(); timer = nil }
    }

    // MARK: Geometry

    private var span: CGFloat { 360 / CGFloat(max(items.count, 1)) }

    /// Degrees, 0 = right, 90 = top. The first item sits on top, the rest go clockwise.
    private func centerAngle(_ i: Int) -> CGFloat { 90 - CGFloat(i) * span }

    func segment(at p: NSPoint) -> Int? {
        guard !items.isEmpty else { return nil }
        let c = Self.center
        let dx = p.x - c.x, dy = p.y - c.y
        let r = hypot(dx, dy)
        guard r >= Self.innerR, r <= Self.outerR + 24 else { return nil }
        var d = 90 - atan2(dy, dx) * 180 / .pi + span / 2
        while d < 0 { d += 360 }
        return Int(d / span) % items.count
    }

    // MARK: Drop target

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if kind == nil {
            let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            setFiles(urls)
        }
        return track(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }

    override func draggingExited(_ sender: NSDraggingInfo?) { hovered = nil }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { hovered != nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let h = hovered, items[h].isEnabled(files) else { return false }
        Log.write("drop \(mode) \(items[h].id) x\(items[h].usable(files).count)")
        controller?.perform(items[h], files: files)
        return true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) { controller?.hide() }

    override func draggingEnded(_ sender: NSDraggingInfo) { controller?.hideSoon() }

    private func track(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        if let s = segment(at: p), items[s].isEnabled(files) { hovered = s } else { hovered = nil }
        guard hovered != nil else { return [] }
        let mask = sender.draggingSourceOperationMask
        if mask.contains(.copy) { return .copy }
        if mask.contains(.generic) { return .generic }
        return mask.contains(.link) ? .link : []
    }

    // MARK: Drawing

    // "Night" palette: deep navy with mint.
    private static let ink = NSColor(srgbRed: 0.92, green: 0.94, blue: 1, alpha: 1)
    private static let mintTop = NSColor(srgbRed: 0.29, green: 0.95, blue: 0.80, alpha: 1)
    private static let mintBottom = NSColor(srgbRed: 0.08, green: 0.72, blue: 0.61, alpha: 1)
    private static let onMint = NSColor(srgbRed: 0.02, green: 0.15, blue: 0.12, alpha: 1)

    override func draw(_ dirtyRect: NSRect) {
        let c = Self.center
        if paintsBackdrop {
            NSGradient(colors: [NSColor(srgbRed: 0.04, green: 0.07, blue: 0.16, alpha: 1),
                                NSColor(srgbRed: 0.08, green: 0.14, blue: 0.34, alpha: 1),
                                NSColor(srgbRed: 0.04, green: 0.23, blue: 0.29, alpha: 1)])?.draw(in: bounds, angle: -70)
            NSColor(srgbRed: 0.10, green: 0.17, blue: 0.40, alpha: 0.85).setFill()
            NSBezierPath(ovalIn: circle(Self.outerR + 10)).fill()
            NSBezierPath(roundedRect: Self.pillsRect, xRadius: Self.pillsRect.height / 2, yRadius: Self.pillsRect.height / 2).fill()
        }

        // Night-blue tint over the glass.
        let ring = NSBezierPath(ovalIn: circle(Self.outerR + 10))
        NSGradient(starting: NSColor(srgbRed: 0.18, green: 0.27, blue: 0.51, alpha: 0.55),
                   ending: NSColor(srgbRed: 0.09, green: 0.16, blue: 0.36, alpha: 0.55))?.draw(in: ring, angle: -90)
        NSColor(white: 1, alpha: 0.22).setStroke()
        ring.lineWidth = 1
        ring.stroke()

        if items.isEmpty {
            let track = NSBezierPath(ovalIn: circle(Self.outerR))
            track.append(NSBezierPath(ovalIn: circle(Self.innerR + 7)).reversed)
            NSColor(white: 1, alpha: kind == nil ? 0.12 : 0.06).setFill()
            track.fill()
        } else {
            let eased = 1 - pow(1 - reveal, 3)
            for i in items.indices { drawSegment(i, appear: eased) }
        }

        let hub = NSBezierPath(ovalIn: circle(Self.innerR))
        NSColor(white: 1, alpha: 0.14).setFill()
        hub.fill()
        drawHub(c)
        drawPills()
    }

    private func circle(_ r: CGFloat) -> NSRect {
        let c = Self.center
        return NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
    }

    private func drawSegment(_ i: Int, appear: CGFloat) {
        let lifted = i < lift.count ? lift[i] : 0
        let mid = centerAngle(i) + (1 - appear) * 24
        let rad = mid * .pi / 180
        let shift = lifted * 7
        let c = NSPoint(x: Self.center.x + cos(rad) * shift, y: Self.center.y + sin(rad) * shift)
        let gap: CGFloat = items.count > 1 ? 1.6 : 0
        let a1 = mid - span / 2 + gap, a2 = mid + span / 2 - gap
        let outer = Self.outerR + lifted * 5

        let path = NSBezierPath()
        if items.count == 1 {
            path.appendOval(in: NSRect(x: c.x - outer, y: c.y - outer, width: 2 * outer, height: 2 * outer))
            path.append(NSBezierPath(ovalIn: circle(Self.innerR + 7)).reversed)
        } else {
            path.appendArc(withCenter: c, radius: outer, startAngle: a1, endAngle: a2, clockwise: false)
            path.appendArc(withCenter: c, radius: Self.innerR + 7, startAngle: a2, endAngle: a1, clockwise: true)
            path.close()
        }

        let enabled = items[i].isEnabled(files)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(appear)
        if hovered == i {
            NSGradient(starting: Self.mintTop, ending: Self.mintBottom)?.draw(in: path, angle: -90)
        } else {
            NSColor(white: 1, alpha: enabled ? 0.12 : 0.04).setFill()
            path.fill()
        }

        let color: NSColor = hovered == i ? Self.onMint : Self.ink.withAlphaComponent(enabled ? 1 : 0.3)
        let r = (Self.innerR + outer) / 2 + 3
        let p = NSPoint(x: c.x + cos(rad) * r, y: c.y + sin(rad) * r)
        if let symbol = items[i].symbol {
            let config = NSImage.SymbolConfiguration(pointSize: 19, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let s = img.size
                img.draw(in: NSRect(x: p.x - s.width / 2, y: p.y + 2, width: s.width, height: s.height))
            }
            let t = text(items[i].title, size: items.count > 5 ? 10.5 : 11.5, weight: .bold, color: color)
            let ts = t.size()
            t.draw(at: NSPoint(x: p.x - ts.width / 2, y: p.y - ts.height - 1))
        } else {
            let t = text(items[i].title, size: items[i].title.count > 4 ? 15 : 17, weight: .heavy, color: color)
            let ts = t.size()
            t.draw(at: NSPoint(x: p.x - ts.width / 2, y: p.y - ts.height / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawHub(_ c: NSPoint) {
        var title = tr("سحبة", "Sahba"), detail = mode.title
        if let kind {
            title = countText(kind)
            if items.isEmpty {
                detail = tr("ما في \(mode.title)", "Not available")
            } else if totalBytes > 0 {
                detail = L10n.size(totalBytes)
            }
        }
        let t = text(title, size: 15, weight: .bold, color: Self.ink)
        let d = text(detail, size: 11, weight: .medium, color: Self.ink.withAlphaComponent(0.65))
        let ts = t.size(), ds = d.size()
        let top = c.y + (ts.height + ds.height) / 2
        t.draw(at: NSPoint(x: c.x - ts.width / 2, y: top - ts.height))
        d.draw(at: NSPoint(x: c.x - ds.width / 2, y: top - ts.height - ds.height))
    }

    private func countText(_ kind: FileKind) -> String {
        let n = files.count
        if kind == .image {
            return L10n.arabic ? (n == 1 ? "صورة" : n == 2 ? "صورتين" : "\(n) صور") : (n == 1 ? "Photo" : "\(n) Photos")
        }
        if n == 1 {
            switch kind {
            case .video: return tr("فيديو", "Video")
            case .audio: return tr("صوت", "Audio")
            case .pdf: return "PDF"
            case .document: return tr("مستند", "Document")
            default: return tr("ملف", "File")
            }
        }
        return L10n.arabic ? (n == 2 ? "ملفين" : "\(n) ملفات") : "\(n) Files"
    }

    /// "⇧ تحويل  ⌘ أدوات  ⌃ إجراءات", right to left, the open one in mint.
    private func drawPills() {
        let modes = WheelMode.allCases
        let w = (Self.pillsRect.width - 8) / CGFloat(modes.count)
        for (i, m) in modes.enumerated() {
            // Reading order: right to left in Arabic, left to right in English.
            let x = L10n.arabic ? Self.pillsRect.maxX - 4 - w * CGFloat(i + 1) : Self.pillsRect.minX + 4 + w * CGFloat(i)
            let r = NSRect(x: x + 2, y: Self.pillsRect.minY + 4, width: w - 4, height: Self.pillsRect.height - 8)
            let active = m == mode
            if active {
                let p = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
                NSGradient(starting: Self.mintTop, ending: Self.mintBottom)?.draw(in: p, angle: -90)
            }
            let t = text(L10n.arabic ? "\(m.title) \(m.key)" : "\(m.key) \(m.title)", size: 12, weight: .bold,
                         color: active ? Self.onMint : Self.ink.withAlphaComponent(0.6))
            let ts = t.size()
            t.draw(at: NSPoint(x: r.midX - ts.width / 2, y: r.midY - ts.height / 2))
        }
    }

    private func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSAttributedString {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    }
}
