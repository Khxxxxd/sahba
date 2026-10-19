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

    /// Apple's frosted glass blur.
    static func glass(_ rect: NSRect, radius: CGFloat) -> NSView {
        let v = NSVisualEffectView(frame: rect)
        v.material = .popover
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
        Log.write("shown \(mode) at \(Int(p.x)),\(Int(p.y)) x\(files.count)")
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
    static let innerR: CGFloat = 54
    static let side: CGFloat = 2 * (outerR + 26)
    static let pillsHeight: CGFloat = 34
    static let size = NSSize(width: side, height: side + pillsHeight + 8)
    static let center = NSPoint(x: side / 2, y: pillsHeight + 8 + side / 2)
    static let pillsRect = NSRect(x: side / 2 - 142, y: 0, width: 284, height: pillsHeight)

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

    // Fluid Liquid Bubble Animation state
    private var selectionAngle: CGFloat = 90
    private var targetAngle: CGFloat = 90
    private var angleVelocity: CGFloat = 0

    private var selectionSpan: CGFloat = 60
    private var targetSpan: CGFloat = 60
    private var spanVelocity: CGFloat = 0

    private var selectionAlpha: CGFloat = 0
    private var slicePuffs: [CGFloat] = []
    private var sliceVelocities: [CGFloat] = []

    private var reveal: CGFloat = 1
    private var timer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    func reset(mode: WheelMode, files: [URL] = []) {
        self.mode = mode
        self.files = files
        self.kind = files.isEmpty ? nil : Kinds.groupKind(files)
        self.totalBytes = files.reduce(0) { $0 + Kinds.size($1) }
        self.items = kind.map { Catalog.items(mode, $0) } ?? []
        self.slicePuffs = Array(repeating: 0, count: items.count)
        self.sliceVelocities = Array(repeating: 0, count: items.count)
        self.selectionAngle = centerAngle(0)
        self.targetAngle = selectionAngle
        self.angleVelocity = 0
        self.selectionSpan = span - 3.6
        self.targetSpan = selectionSpan
        self.spanVelocity = 0
        self.selectionAlpha = 0
        self.hovered = nil
        self.reveal = 1
        self.needsDisplay = true
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
        slicePuffs = Array(repeating: 0, count: items.count)
        sliceVelocities = Array(repeating: 0, count: items.count)
        selectionAngle = centerAngle(0)
        targetAngle = selectionAngle
        angleVelocity = 0
        selectionSpan = span - 3.6
        targetSpan = selectionSpan
        spanVelocity = 0
        selectionAlpha = 0
        reveal = 1
        needsDisplay = true
    }

    func finishAnimations() {
        reveal = 1
        if let h = hovered, h < items.count {
            selectionAngle = centerAngle(h)
            targetAngle = selectionAngle
            selectionAlpha = 1.0
            selectionSpan = span - 3.6
            for i in slicePuffs.indices { slicePuffs[i] = i == h ? 1.0 : 0.0 }
        } else {
            selectionAlpha = 0.0
            for i in slicePuffs.indices { slicePuffs[i] = 0.0 }
        }
    }

    private func animate() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func shortestAngleDelta(from a: CGFloat, to b: CGFloat) -> CGFloat {
        var diff = (b - a).truncatingRemainder(dividingBy: 360)
        if diff > 180 { diff -= 360 }
        if diff < -180 { diff += 360 }
        return diff
    }

    private func tick() {
        var moving = false
        if reveal < 1 {
            reveal = min(1, reveal + 1.0 / 12)
            moving = true
        }

        // Selection alpha fade
        let targetAlpha: CGFloat = (hovered != nil && !items.isEmpty) ? 1.0 : 0.0
        let alphaDiff = targetAlpha - selectionAlpha
        if abs(alphaDiff) > 0.01 {
            selectionAlpha += alphaDiff * 0.28
            moving = true
        } else {
            selectionAlpha = targetAlpha
        }

        if let h = hovered, h < items.count {
            targetAngle = centerAngle(h)
        }

        // Angle spring physics
        let baseSpan = span - 3.6
        let angleDiff = shortestAngleDelta(from: selectionAngle, to: targetAngle)
        let springForce = angleDiff * 0.22
        angleVelocity = (angleVelocity + springForce) * 0.72
        selectionAngle += angleVelocity
        if abs(angleDiff) > 0.05 || abs(angleVelocity) > 0.05 {
            moving = true
        } else {
            selectionAngle = targetAngle
            angleVelocity = 0
        }

        // Span stretching physics (liquid elongation while traveling)
        let stretch = min(22.0, abs(angleDiff) * 0.45)
        let desiredSpan = baseSpan + stretch
        let spanDiff = desiredSpan - selectionSpan
        spanVelocity = (spanVelocity + spanDiff * 0.24) * 0.70
        selectionSpan += spanVelocity
        if abs(spanDiff) > 0.05 || abs(spanVelocity) > 0.05 {
            moving = true
        } else {
            selectionSpan = baseSpan
            spanVelocity = 0
        }

        // Individual slice elastic scale puffs
        for i in slicePuffs.indices {
            let isHovered = hovered == i
            let targetPuff: CGFloat = isHovered ? 1.0 : 0.0
            let pDiff = targetPuff - slicePuffs[i]
            sliceVelocities[i] = (sliceVelocities[i] + pDiff * 0.25) * 0.72
            slicePuffs[i] += sliceVelocities[i]
            if abs(pDiff) > 0.01 || abs(sliceVelocities[i]) > 0.01 {
                moving = true
            } else {
                slicePuffs[i] = targetPuff
                sliceVelocities[i] = 0
            }
        }

        needsDisplay = true
        if !moving {
            timer?.invalidate()
            timer = nil
        }
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

    func pillRect(for m: WheelMode) -> NSRect {
        let modes = WheelMode.allCases
        guard let i = modes.firstIndex(of: m) else { return .zero }
        let w = (Self.pillsRect.width - 8) / CGFloat(modes.count)
        let x = L10n.arabic
            ? Self.pillsRect.maxX - 4 - w * CGFloat(i + 1)
            : Self.pillsRect.minX + 4 + w * CGFloat(i)
        return NSRect(x: x + 2, y: Self.pillsRect.minY + 3, width: w - 4, height: Self.pillsRect.height - 6)
    }

    func mode(at p: NSPoint) -> WheelMode? {
        guard Self.pillsRect.contains(p) else { return nil }
        for m in WheelMode.allCases {
            if pillRect(for: m).contains(p) { return m }
        }
        return nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let m = mode(at: p) {
            setMode(m)
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
    }

    // MARK: Drop target

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if kind == nil || files.isEmpty {
            let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            if !urls.isEmpty { setFiles(urls) }
        }
        return track(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if files.isEmpty {
            let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            if !urls.isEmpty { setFiles(urls) }
        }
        return track(sender)
    }

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
        if let targetMode = mode(at: p) {
            if targetMode != mode {
                setMode(targetMode)
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            hovered = nil
            return []
        }
        if let s = segment(at: p), items[s].isEnabled(files) { hovered = s } else { hovered = nil }
        guard hovered != nil else { return [] }
        let mask = sender.draggingSourceOperationMask
        if mask.contains(.copy) { return .copy }
        if mask.contains(.generic) { return .generic }
        if mask.contains(.move) { return .copy }
        return mask.contains(.link) ? .link : []
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let c = Self.center
        let outerGlassR = Self.outerR + 10
        let ringRect = circle(outerGlassR)

        if paintsBackdrop {
            // Modern macOS dark desktop wallpaper simulation for snapshots
            let bg = NSGradient(colors: [
                NSColor(srgbRed: 0.08, green: 0.11, blue: 0.18, alpha: 1.0),
                NSColor(srgbRed: 0.04, green: 0.07, blue: 0.12, alpha: 1.0),
                NSColor(srgbRed: 0.02, green: 0.04, blue: 0.08, alpha: 1.0)
            ])
            bg?.draw(in: bounds, angle: -65)

            // Realistic glass drop shadows
            NSGraphicsContext.saveGraphicsState()
            let shadowCtx = NSGraphicsContext.current?.cgContext
            shadowCtx?.setShadow(offset: CGSize(width: 0, height: -6), blur: 20, color: NSColor.black.withAlphaComponent(0.55).cgColor)
            NSColor(srgbRed: 0.08, green: 0.10, blue: 0.16, alpha: 0.90).setFill()
            NSBezierPath(ovalIn: ringRect).fill()
            NSBezierPath(roundedRect: Self.pillsRect, xRadius: Self.pillsRect.height / 2, yRadius: Self.pillsRect.height / 2).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        // Obsidian glass tint
        let ring = NSBezierPath(ovalIn: ringRect)
        Theme.glassTintGradient?.draw(in: ring, angle: -90)

        // Outer specular rim (top catches ambient light)
        NSGraphicsContext.saveGraphicsState()
        Theme.rimTop.setStroke()
        ring.lineWidth = 1.0
        ring.stroke()
        NSGraphicsContext.restoreGraphicsState()

        if items.isEmpty {
            let track = NSBezierPath(ovalIn: circle(Self.outerR))
            track.append(NSBezierPath(ovalIn: circle(Self.innerR + 6)).reversed)
            NSColor(white: 1, alpha: kind == nil ? 0.08 : 0.04).setFill()
            track.fill()
        } else {
            let eased = 1 - pow(1 - reveal, 3)
            drawBubblySlices(center: c, appear: eased)
        }

        drawHub(c)
        drawPills()
    }

    private func circle(_ r: CGFloat) -> NSRect {
        let c = Self.center
        return NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
    }

    private func bubbleWedgeCG(center c: CGPoint, innerR: CGFloat, outerR: CGFloat, a1Deg: CGFloat, a2Deg: CGFloat, r: CGFloat) -> CGPath {
        let a1 = a1Deg * .pi / 180
        let a2 = a2Deg * .pi / 180
        let path = CGMutablePath()

        let dOut = r / outerR
        let dIn = r / innerR

        let midOuterA1 = a1 + dOut
        let midOuterA2 = a2 - dOut
        let midInnerA1 = a1 + dIn
        let midInnerA2 = a2 - dIn

        let startPt = CGPoint(x: c.x + cos(a1) * (innerR + r), y: c.y + sin(a1) * (innerR + r))
        path.move(to: startPt)

        let pOuterA1 = CGPoint(x: c.x + cos(a1) * (outerR - r), y: c.y + sin(a1) * (outerR - r))
        path.addLine(to: pOuterA1)

        let pArcStart = CGPoint(x: c.x + cos(midOuterA1) * outerR, y: c.y + sin(midOuterA1) * outerR)
        let pCorner1 = CGPoint(x: c.x + cos(a1) * outerR, y: c.y + sin(a1) * outerR)
        path.addQuadCurve(to: pArcStart, control: pCorner1)

        path.addArc(center: c, radius: outerR, startAngle: midOuterA1, endAngle: midOuterA2, clockwise: false)

        let pCorner2 = CGPoint(x: c.x + cos(a2) * outerR, y: c.y + sin(a2) * outerR)
        let pLineA2Start = CGPoint(x: c.x + cos(a2) * (outerR - r), y: c.y + sin(a2) * (outerR - r))
        path.addQuadCurve(to: pLineA2Start, control: pCorner2)

        let pLineA2End = CGPoint(x: c.x + cos(a2) * (innerR + r), y: c.y + sin(a2) * (innerR + r))
        path.addLine(to: pLineA2End)

        let pCorner3 = CGPoint(x: c.x + cos(a2) * innerR, y: c.y + sin(a2) * innerR)
        let pInnerArcStart = CGPoint(x: c.x + cos(midInnerA2) * innerR, y: c.y + sin(midInnerA2) * innerR)
        path.addQuadCurve(to: pInnerArcStart, control: pCorner3)

        path.addArc(center: c, radius: innerR, startAngle: midInnerA2, endAngle: midInnerA1, clockwise: true)

        let pCorner4 = CGPoint(x: c.x + cos(a1) * innerR, y: c.y + sin(a1) * innerR)
        path.addQuadCurve(to: startPt, control: pCorner4)

        path.closeSubpath()
        return path
    }

    private func blendColors(from c1: NSColor, to c2: NSColor, fraction: CGFloat) -> NSColor {
        let f = max(0.0, min(1.0, fraction))
        guard let rgb1 = c1.usingColorSpace(.sRGB),
              let rgb2 = c2.usingColorSpace(.sRGB) else { return f > 0.5 ? c2 : c1 }
        return NSColor(
            srgbRed: rgb1.redComponent + (rgb2.redComponent - rgb1.redComponent) * f,
            green: rgb1.greenComponent + (rgb2.greenComponent - rgb1.greenComponent) * f,
            blue: rgb1.blueComponent + (rgb2.blueComponent - rgb1.blueComponent) * f,
            alpha: rgb1.alphaComponent + (rgb2.alphaComponent - rgb1.alphaComponent) * f
        )
    }

    private func drawBubblySlices(center c: NSPoint, appear: CGFloat) {
        guard !items.isEmpty else { return }

        let count = items.count
        let baseSpan = span
        let gap: CGFloat = count > 1 ? 3.6 : 0.0
        let cornerR: CGFloat = min(13.0, (Self.outerR - Self.innerR) / 2)

        // 1. Idle Crystal Glass Slices
        for i in items.indices {
            let mid = centerAngle(i) + (1 - appear) * 20
            let a1 = mid - baseSpan / 2 + gap
            let a2 = mid + baseSpan / 2 - gap

            let puff = i < slicePuffs.count ? slicePuffs[i] : 0
            let rShift = puff * 3.0
            let rad = mid * .pi / 180
            let sliceCenter = NSPoint(x: c.x + cos(rad) * rShift,
                                      y: c.y + sin(rad) * rShift)

            let path = bubbleWedgeCG(center: sliceCenter,
                                     innerR: Self.innerR + 6,
                                     outerR: Self.outerR + 2 + puff * 3.0,
                                     a1Deg: a1,
                                     a2Deg: a2,
                                     r: cornerR)

            NSGraphicsContext.saveGraphicsState()
            guard let ctx = NSGraphicsContext.current?.cgContext else {
                NSGraphicsContext.restoreGraphicsState()
                continue
            }
            ctx.setAlpha(appear)

            let enabled = items[i].isEnabled(files)

            // Crystal glass body
            ctx.saveGState()
            let fillColor = enabled ? NSColor(white: 1.0, alpha: 0.08) : NSColor(white: 1.0, alpha: 0.03)
            ctx.setFillColor(fillColor.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()

            // Crystal glass specular rim
            ctx.saveGState()
            let strokeColor = enabled ? NSColor(white: 1.0, alpha: 0.18) : NSColor(white: 1.0, alpha: 0.05)
            ctx.setStrokeColor(strokeColor.cgColor)
            ctx.setLineWidth(1.1)
            ctx.addPath(path)
            ctx.strokePath()
            ctx.restoreGState()

            NSGraphicsContext.restoreGraphicsState()
        }

        // 2. Liquid Fluid Merging Bubble (active selection)
        if selectionAlpha > 0.01 {
            let activePuff = hovered.flatMap { $0 < slicePuffs.count ? slicePuffs[$0] : nil } ?? 0.5
            let puffShift = activePuff * 4.0
            let rad = selectionAngle * .pi / 180
            let fluidCenter = NSPoint(x: c.x + cos(rad) * puffShift,
                                      y: c.y + sin(rad) * puffShift)

            let a1 = selectionAngle - selectionSpan / 2
            let a2 = selectionAngle + selectionSpan / 2
            let fluidCornerR: CGFloat = min(14.0, (Self.outerR - Self.innerR) / 2)

            let liquidPath = bubbleWedgeCG(center: fluidCenter,
                                           innerR: Self.innerR + 4,
                                           outerR: Self.outerR + 4 + activePuff * 4.0,
                                           a1Deg: a1,
                                           a2Deg: a2,
                                           r: fluidCornerR)

            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.setAlpha(selectionAlpha * appear)

                // Soft glowing ambient liquid shadow
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 18, color: Theme.accentGlow.cgColor)
                let nsLiquid = NSBezierPath(cgPath: liquidPath)
                Theme.accentGradient?.draw(in: nsLiquid, angle: -90)
                ctx.restoreGState()

                // Specular liquid rim highlight
                ctx.saveGState()
                ctx.addPath(liquidPath)
                ctx.setStrokeColor(NSColor(white: 1.0, alpha: 0.50).cgColor)
                ctx.setLineWidth(1.3)
                ctx.strokePath()
                ctx.restoreGState()
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        // 3. Icons & Typography with fluid morphing colors
        for i in items.indices {
            let mid = centerAngle(i) + (1 - appear) * 20
            let puff = i < slicePuffs.count ? slicePuffs[i] : 0
            let rShift = puff * 3.0
            let rad = mid * .pi / 180
            let rPos = (Self.innerR + 6 + Self.outerR + 2) / 2 + puff * 2.0
            let p = NSPoint(x: c.x + cos(rad) * (rPos + rShift),
                            y: c.y + sin(rad) * (rPos + rShift))

            let enabled = items[i].isEnabled(files)

            // Fluid proximity to selection bubble
            let angleDist = abs(shortestAngleDelta(from: mid, to: selectionAngle))
            let proximity: CGFloat = selectionAlpha * max(0.0, 1.0 - (angleDist / (baseSpan * 0.70)))

            let activeColor = Theme.onAccent
            let idleColor = enabled ? Theme.labelPrimary : Theme.labelTertiary
            let textColor = blendColors(from: idleColor, to: activeColor, fraction: proximity)

            let idleSymColor = enabled ? Theme.accentTop : Theme.labelSecondary.withAlphaComponent(0.4)
            let symColor = blendColors(from: idleSymColor, to: activeColor, fraction: proximity)

            NSGraphicsContext.saveGraphicsState()
            if let symbol = items[i].symbol {
                let config = NSImage.SymbolConfiguration(pointSize: count > 5 ? 18 : 20, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [symColor]))
                if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                    let s = img.size
                    img.draw(in: NSRect(x: p.x - s.width / 2, y: p.y + 1, width: s.width, height: s.height))
                }
                let t = text(items[i].title, size: count > 5 ? 10.5 : 11.5, weight: .bold, color: textColor)
                let ts = t.size()
                t.draw(at: NSPoint(x: p.x - ts.width / 2, y: p.y - ts.height - 2))
            } else {
                let t = text(items[i].title, size: items[i].title.count > 4 ? 14 : 16, weight: .heavy, color: textColor)
                let ts = t.size()
                t.draw(at: NSPoint(x: p.x - ts.width / 2, y: p.y - ts.height / 2))
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawHub(_ c: NSPoint) {
        let hubR: CGFloat = Self.innerR - 3
        let hubRect = NSRect(x: c.x - hubR, y: c.y - hubR, width: 2 * hubR, height: 2 * hubR)
        let hubPath = NSBezierPath(ovalIn: hubRect)

        NSGraphicsContext.saveGraphicsState()
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            NSGraphicsContext.restoreGraphicsState()
            return
        }

        // Lens base glass
        let lensGrad = NSGradient(starting: NSColor(srgbRed: 0.12, green: 0.15, blue: 0.22, alpha: 0.90),
                                  ending: NSColor(srgbRed: 0.05, green: 0.07, blue: 0.11, alpha: 0.96))
        lensGrad?.draw(in: hubPath, angle: -90)

        // Outer specular rim
        Theme.rimTop.setStroke()
        hubPath.lineWidth = 1.2
        hubPath.stroke()

        // Inner optical ring track
        let innerR = hubR - 5
        let innerRing = NSBezierPath(ovalIn: NSRect(x: c.x - innerR, y: c.y - innerR, width: 2 * innerR, height: 2 * innerR))
        NSColor(white: 1.0, alpha: 0.08).setStroke()
        innerRing.lineWidth = 1.0
        innerRing.stroke()

        // Spherical crystal lens highlight arc (convex dome effect)
        let highlightPath = CGMutablePath()
        highlightPath.addArc(center: CGPoint(x: c.x, y: c.y + 4), radius: hubR - 5, startAngle: 30 * .pi / 180, endAngle: 150 * .pi / 180, clockwise: false)
        ctx.saveGState()
        ctx.addPath(highlightPath)
        ctx.setStrokeColor(NSColor(white: 1.0, alpha: 0.32).cgColor)
        ctx.setLineWidth(1.4)
        ctx.strokePath()
        ctx.restoreGState()

        if let h = hovered, h < items.count {
            // Live action preview in Lens
            let item = items[h]
            let sym = item.symbol ?? (mode == .convert ? "arrow.triangle.2.circlepath" : "hand.tap.fill")
            let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [Theme.accentTop]))
            if let img = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let s = img.size
                img.draw(in: NSRect(x: c.x - s.width / 2, y: c.y + 4, width: s.width, height: s.height))
            }
            let t = text(item.title, size: 12.5, weight: .bold, color: Theme.labelPrimary)
            let ts = t.size()
            t.draw(at: NSPoint(x: c.x - ts.width / 2, y: c.y - 12))
            let d = text(mode.title, size: 9.5, weight: .medium, color: Theme.accentTop)
            let ds = d.size()
            d.draw(at: NSPoint(x: c.x - ds.width / 2, y: c.y - 13 - ds.height))
        } else {
            // Idle Lens
            let iconName = kind?.symbol ?? "circle.dashed.inset.filled"
            let config = NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [Theme.accentTop]))
            if let img = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let s = img.size
                img.draw(in: NSRect(x: c.x - s.width / 2, y: c.y + 5, width: s.width, height: s.height))
            }

            var title = tr("سحبة", "Sahba")
            var detail = mode.title
            if let kind {
                title = countText(kind)
                if items.isEmpty {
                    detail = tr("ما في \(mode.title)", "Not available")
                } else if totalBytes > 0 {
                    detail = L10n.size(totalBytes)
                }
            }

            let t = text(title, size: 12.5, weight: .bold, color: Theme.labelPrimary)
            let d = text(detail, size: 9.5, weight: .medium, color: Theme.labelSecondary)
            let ts = t.size(), ds = d.size()
            t.draw(at: NSPoint(x: c.x - ts.width / 2, y: c.y - 12))
            d.draw(at: NSPoint(x: c.x - ds.width / 2, y: c.y - 12 - ds.height))
        }

        NSGraphicsContext.restoreGraphicsState()
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

    private func drawPills() {
        let capsule = NSBezierPath(roundedRect: Self.pillsRect,
                                   xRadius: Self.pillsRect.height / 2,
                                   yRadius: Self.pillsRect.height / 2)
        Theme.glassTintGradient?.draw(in: capsule, angle: -90)
        Theme.rimTop.setStroke()
        capsule.lineWidth = 1.0
        capsule.stroke()

        for m in WheelMode.allCases {
            let r = pillRect(for: m)
            let active = m == mode
            if active {
                let p = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
                Theme.accentGradient?.draw(in: p, angle: -90)
                Theme.rimTop.setStroke()
                p.lineWidth = 1.0
                p.stroke()
            }

            let sym = m.symbol
            let symColor = active ? Theme.onAccent : Theme.labelSecondary
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [symColor]))
            let img = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?.withSymbolConfiguration(config)

            let titleStr = L10n.arabic ? "\(m.title) \(m.key)" : "\(m.key) \(m.title)"
            let t = text(titleStr, size: 11.5, weight: active ? .bold : .semibold,
                         color: active ? Theme.onAccent : Theme.labelSecondary)
            let ts = t.size()
            let iconW = img?.size.width ?? 0
            let spacing: CGFloat = 5
            let totalW = iconW + spacing + ts.width
            let startX = r.midX - totalW / 2

            if let img {
                let imgH = img.size.height
                img.draw(in: NSRect(x: startX, y: r.midY - imgH / 2 + 0.5, width: iconW, height: imgH))
            }
            t.draw(at: NSPoint(x: startX + iconW + spacing, y: r.midY - ts.height / 2))
        }
    }

    private func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSAttributedString {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    }
}
