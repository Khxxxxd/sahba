import AVKit
import SwiftUI

/// Small windows for tools that need a choice first: compress, crop, trim.
enum ToolWindows {
    private static var open: [NSWindow] = []

    @discardableResult
    static func present<V: View>(_ title: String, _ content: V) -> NSWindow {
        let host = NSHostingController(rootView: content.environment(\.layoutDirection, L10n.arabic ? .rightToLeft : .leftToRight))
        let w = NSWindow(contentViewController: host)
        w.title = title
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        open.append(w)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            open.removeAll { $0 === w }
        }
        return w
    }

    /// Lets a SwiftUI view close the window it lives in.
    final class Handle { weak var window: NSWindow?; func close() { window?.close() } }

    static func compress(_ files: [URL], kind: FileKind) {
        let handle = Handle()
        let view = CompressView(files: files, kind: kind) { fraction in
            handle.close()
            guard let fraction else { return }
            Jobs.perFile(tr("ضغط", "Compressing"), files: files) { url, p in
                switch kind {
                case .image: return [try ImageOps.compress(url, quality: fraction)]
                case .video: return [try MediaOps.compressVideo(url, fraction: fraction, progress: p)]
                default: return [try MediaOps.compressAudio(url, fraction: fraction, progress: p)]
                }
            }
        }
        handle.window = present(tr("ضغط", "Compress"), view)
    }

    static func crop(_ url: URL) {
        guard let image = ImageOps.orientedImage(url) else { HUD.shared.flash(tr("ما قدرت أفتح الصورة", "Couldn't open the photo"), failed: true); return }
        let handle = Handle()
        let view = CropView(image: image, name: url.lastPathComponent) { rect in
            handle.close()
            guard let rect else { return }
            Jobs.perFile(tr("قص", "Cropping"), files: [url]) { url, _ in [try ImageOps.crop(url, rect: rect)] }
        }
        handle.window = present(tr("قص الصورة", "Crop Photo"), view)
    }

    static func trim(_ url: URL) {
        let duration = CMTimeGetSeconds(AVURLAsset(url: url).duration)
        let length = duration.isFinite && duration > 0 ? duration : FF.info(url).duration
        guard length > 0 else { HUD.shared.flash(tr("ما قدرت أقرا المدة", "Couldn't read the length"), failed: true); return }
        let handle = Handle()
        let view = TrimView(url: url, duration: length, isVideo: Kinds.kind(url) == .video) { range in
            handle.close()
            guard let range else { return }
            Jobs.perFile(tr("قص", "Trimming"), files: [url]) { url, p in [try MediaOps.trim(url, start: range.0, end: range.1, progress: p)] }
        }
        handle.window = present(tr("قص المقطع", "Trim Clip"), view)
    }
}

private func sizeText(_ bytes: Int64) -> String { L10n.size(bytes) }

private func header(_ symbol: String, _ title: String, _ detail: String) -> some View {
    HStack(spacing: 12) {
        Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(Color.sahbaMint).frame(width: 30)
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 15, weight: .bold, design: .rounded)).lineLimit(1).truncationMode(.middle)
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
    }
}

// MARK: - Compress

final class CompressModel: ObservableObject {
    @Published var percent: Double = 60
    @Published var estimate: Int64?
}

// SwiftUI's @State is a macro the command-line tools can't expand, so state lives in small models.
struct CompressView: View {
    let files: [URL]
    let kind: FileKind
    let onDone: (Double?) -> Void
    @ObservedObject var model = CompressModel()

    private var original: Int64 { files.reduce(0) { $0 + Kinds.size($1) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header("arrow.down.right.and.arrow.up.left",
                   files.count == 1 ? files[0].lastPathComponent : tr("\(files.count) ملفات", "\(files.count) files"),
                   tr("الحجم الحين: \(sizeText(original))", "Now: \(sizeText(original))"))
            VStack(alignment: .leading, spacing: 6) {
                Text(kind == .image ? tr("الجودة: \(Int(model.percent))٪", "Quality: \(Int(model.percent))%")
                                     : tr("الحجم الجديد: \(Int(model.percent))٪ من الأصلي", "New size: \(Int(model.percent))% of the original"))
                    .font(.system(size: 13, weight: .medium))
                Slider(value: $model.percent, in: 10...90, step: 5)
            }
            HStack {
                Text(tr("المتوقع:", "Expected:")).foregroundStyle(.secondary)
                Text(model.estimate.map(sizeText) ?? "…").font(.system(size: 18, weight: .bold, design: .rounded)).monospacedDigit()
            }
            HStack {
                Spacer()
                Button(tr("إلغاء", "Cancel")) { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button(tr("احفظ", "Save")) { onDone(model.percent / 100) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).padding(.top, 8)
        .frame(width: 400)
        .task(id: model.percent) { await recompute() }
    }

    private func recompute() async {
        let fraction = model.percent / 100
        guard kind == .image else { model.estimate = Int64(Double(original) * fraction); return }
        model.estimate = nil
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }
        let files = self.files
        let total = await Task.detached(priority: .userInitiated) {
            files.reduce(Int64(0)) { $0 + Int64(ImageOps.estimate($1, quality: fraction) ?? 0) }
        }.value
        if !Task.isCancelled { model.estimate = total }
    }
}

// MARK: - Crop

final class CropModel: ObservableObject {
    /// Normalised (0…1), origin at the top-left of the image.
    @Published var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @Published var ratioIndex = 0
    var dragStart: CGRect?
}

struct CropView: View {
    let image: CGImage
    let name: String
    let onDone: (CGRect?) -> Void

    @ObservedObject var model = CropModel()

    private static let ratioValues: [CGFloat?] = [nil, 1, 4.0 / 3, 16.0 / 9, 9.0 / 16]
    private static let arabicNames = ["حر", "١:١", "٤:٣", "١٦:٩", "٩:١٦"]
    private static let englishNames = ["Free", "1:1", "4:3", "16:9", "9:16"]
    private let ratios: [(String, CGFloat?)] = Array(zip(L10n.arabic ? CropView.arabicNames : CropView.englishNames, CropView.ratioValues))
    private var pw: CGFloat { CGFloat(image.width) }
    private var ph: CGFloat { CGFloat(image.height) }
    private var ratio: CGFloat? { ratios[model.ratioIndex].1 }

    private var display: CGSize {
        let s = min(560 / pw, 420 / ph)
        return CGSize(width: pw * s, height: ph * s)
    }

    var body: some View {
        VStack(spacing: 16) {
            header("crop", name, tr("اسحب الزوايا، أو حرّك المربع", "Drag the corners, or move the box"))
            canvas.environment(\.layoutDirection, .leftToRight).padding(10)
            Picker("", selection: $model.ratioIndex) {
                ForEach(ratios.indices, id: \.self) { Text(ratios[$0].0).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 360)
            .onChange(of: model.ratioIndex) { _ in applyRatio() }
            HStack {
                Text(verbatim: "\(Int((model.rect.width * pw).rounded())) × \(Int((model.rect.height * ph).rounded())) \(tr("بكسل", "px"))")
                    .monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button(tr("رجّع", "Reset")) { model.rect = CGRect(x: 0, y: 0, width: 1, height: 1); model.ratioIndex = 0 }
                Button(tr("إلغاء", "Cancel")) { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button(tr("احفظ", "Save")) { onDone(model.rect) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).padding(.top, 8)
    }

    private var canvas: some View {
        let size = display
        let r = CGRect(x: model.rect.minX * size.width, y: model.rect.minY * size.height,
                       width: model.rect.width * size.width, height: model.rect.height * size.height)
        return ZStack(alignment: .topLeading) {
            Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
            Path { p in
                p.addRect(CGRect(origin: .zero, size: size))
                p.addRect(r)
            }
            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            Rectangle().strokeBorder(Color.sahbaMint, lineWidth: 2)
                .frame(width: r.width, height: r.height)
                .contentShape(Rectangle())
                .offset(x: r.minX, y: r.minY)
                .gesture(moveGesture(size))
            ForEach(0..<4, id: \.self) { corner in
                Circle().fill(Color.white).overlay(Circle().stroke(Color.sahbaMint, lineWidth: 2.5))
                    .frame(width: 18, height: 18)
                    .offset(x: (corner % 2 == 0 ? r.minX : r.maxX) - 9, y: (corner < 2 ? r.minY : r.maxY) - 9)
                    .gesture(cornerGesture(corner, size))
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), hi) }

    private func moveGesture(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { g in
                if model.dragStart == nil { model.dragStart = model.rect }
                guard let s = model.dragStart else { return }
                model.rect.origin.x = clamp(s.minX + g.translation.width / size.width, 0, 1 - s.width)
                model.rect.origin.y = clamp(s.minY + g.translation.height / size.height, 0, 1 - s.height)
            }
            .onEnded { _ in model.dragStart = nil }
    }

    /// Corners: 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right.
    private func cornerGesture(_ corner: Int, _ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if model.dragStart == nil { model.dragStart = model.rect }
                guard let s = model.dragStart else { return }
                let dx = g.translation.width / size.width, dy = g.translation.height / size.height
                let left = corner % 2 == 0, top = corner < 2
                var minX = s.minX, maxX = s.maxX, minY = s.minY, maxY = s.maxY
                if left { minX = clamp(s.minX + dx, 0, s.maxX - 0.05) } else { maxX = clamp(s.maxX + dx, s.minX + 0.05, 1) }
                if top { minY = clamp(s.minY + dy, 0, s.maxY - 0.05) } else { maxY = clamp(s.maxY + dy, s.minY + 0.05, 1) }
                if let ratio {
                    // Keep the shape: height follows width, anchored at the opposite corner.
                    var w = maxX - minX
                    var h = w * pw / (ph * ratio)
                    let room = top ? maxY : 1 - minY
                    if h > room { h = room; w = h * ph * ratio / pw }
                    if left { minX = maxX - w } else { maxX = minX + w }
                    if top { minY = maxY - h } else { maxY = minY + h }
                }
                model.rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
            .onEnded { _ in model.dragStart = nil }
    }

    private func applyRatio() {
        guard let ratio else { return }
        var w: CGFloat = 1
        var h = w * pw / (ph * ratio)
        if h > 1 { h = 1; w = h * ph * ratio / pw }
        let cx = clamp(model.rect.midX, w / 2, 1 - w / 2), cy = clamp(model.rect.midY, h / 2, 1 - h / 2)
        model.rect = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }
}

// MARK: - Trim

final class TrimModel: ObservableObject {
    @Published var start: Double = 0
    @Published var end: Double
    let player: AVPlayer
    init(url: URL, duration: Double) { end = duration; player = AVPlayer(url: url) }
}

struct TrimView: View {
    let url: URL
    let duration: Double
    let isVideo: Bool
    let onDone: ((Double, Double)?) -> Void
    @ObservedObject var model: TrimModel
    private var player: AVPlayer { model.player }

    init(url: URL, duration: Double, isVideo: Bool, onDone: @escaping ((Double, Double)?) -> Void) {
        self.url = url
        self.duration = duration
        self.isVideo = isVideo
        self.onDone = onDone
        model = TrimModel(url: url, duration: duration)
    }

    var body: some View {
        VStack(spacing: 14) {
            header("scissors", url.lastPathComponent, tr("حرّك الطرفين وتختار المقطع اللي تبيه", "Drag both ends to pick the part you want"))
            PlayerView(player: player).frame(width: 560, height: isVideo ? 315 : 54)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Group {
                RangeBar(start: $model.start, end: $model.end, duration: duration) { seek($0) }.frame(width: 560, height: 36)
                HStack {
                    Text(clock(model.start))
                    Spacer()
                    Text(tr("المدة \(clock(model.end - model.start))", "Length \(clock(model.end - model.start))")).bold()
                    Spacer()
                    Text(clock(model.end))
                }
                .monospacedDigit().font(.system(size: 12)).frame(width: 560)
            }
            .environment(\.layoutDirection, .leftToRight)
            HStack {
                Button { preview() } label: { Label(tr("شغّل المقطع", "Play selection"), systemImage: "play.fill") }
                Spacer()
                Button(tr("إلغاء", "Cancel")) { player.pause(); onDone(nil) }.keyboardShortcut(.cancelAction)
                Button(tr("احفظ", "Save")) { player.pause(); onDone((model.start, model.end)) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).padding(.top, 8)
        .onDisappear { player.pause() }
    }

    private func seek(_ t: Double) {
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func preview() {
        seek(model.start)
        player.play()
        let stopAt = model.end
        DispatchQueue.main.asyncAfter(deadline: .now() + (model.end - model.start)) {
            if CMTimeGetSeconds(player.currentTime()) >= stopAt - 0.3 { player.pause() }
        }
    }

    private func clock(_ t: Double) -> String {
        let s = max(0, t)
        return String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .inline
        v.showsFullScreenToggleButton = false
        return v
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}

/// A timeline with two handles for the start and end of the clip.
struct RangeBar: View {
    @Binding var start: Double
    @Binding var end: Double
    let duration: Double
    let onScrub: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x1 = CGFloat(start / duration) * w, x2 = CGFloat(end / duration) * w
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25)).frame(height: 8)
                Capsule().fill(Color.sahbaMint).frame(width: max(0, x2 - x1), height: 8).offset(x: x1)
                handle.offset(x: x1 - 6).gesture(drag(w) { t in start = min(max(0, t), end - 0.2); onScrub(start) })
                handle.offset(x: x2 - 6).gesture(drag(w) { t in end = max(min(duration, t), start + 0.2); onScrub(end) })
            }
            .frame(maxHeight: .infinity)
        }
        .coordinateSpace(name: "bar")
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 4).fill(Color.white)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.sahbaMint, lineWidth: 2.5))
            .frame(width: 12, height: 32).shadow(radius: 1)
    }

    private func drag(_ width: CGFloat, _ set: @escaping (Double) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("bar"))
            .onChanged { g in set(Double(g.location.x / width) * duration) }
    }
}
