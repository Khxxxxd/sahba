import AppKit

/// Which wheel is open: Shift = convert, Cmd = tools, Ctrl = actions.
enum WheelMode: Int, CaseIterable {
    case convert, tools, actions

    var title: String { [tr("تحويل", "Convert"), tr("أدوات", "Tools"), tr("إجراءات", "Actions")][rawValue] }
    var key: String { ["⇧", "⌘", "⌃"][rawValue] }

    /// The wheels whose keys are down right now.
    static func held(_ flags: NSEvent.ModifierFlags) -> [WheelMode] {
        [(NSEvent.ModifierFlags.shift, WheelMode.convert), (.command, .tools), (.control, .actions)]
            .filter { flags.contains($0.0) }.map(\.1)
    }
}

/// One segment on the wheel.
struct WheelItem {
    enum Action {
        /// Runs once per file in the background, with progress.
        case perFile(String, (URL, @escaping (Double) -> Void) throws -> [URL])
        /// Runs once for all files together (merging).
        case together(String, ([URL], @escaping (Double) -> Void) throws -> [URL])
        /// Opens a window to pick options first.
        case window(([URL]) -> Void)
        /// Happens right away (copy path, AirDrop...).
        case now(([URL]) -> Void)
    }

    let id: String
    let title: String
    var symbol: String?
    /// Which of the dragged files this segment applies to.
    var accepts: (URL) -> Bool = { _ in true }
    var minCount = 1
    var maxCount = Int.max
    let action: Action

    func usable(_ files: [URL]) -> [URL] { files.filter(accepts) }

    func isEnabled(_ files: [URL]) -> Bool {
        let n = usable(files).count
        return n >= minCount && n <= maxCount
    }
}

enum Catalog {
    static func items(_ mode: WheelMode, _ kind: FileKind) -> [WheelItem] {
        switch mode {
        case .convert: return convert(kind)
        case .tools: return tools(kind)
        case .actions: return actions
        }
    }

    // MARK: Shift: convert

    private static func convert(_ kind: FileKind) -> [WheelItem] {
        func item(_ t: Target, _ work: @escaping (URL, @escaping (Double) -> Void) throws -> [URL]) -> WheelItem {
            WheelItem(id: t.ext, title: t.label, accepts: { !t.matches($0) }, action: .perFile(tr("إلى \(t.label)", "To \(t.label)"), work))
        }
        switch kind {
        case .image:
            return ([Target.png, .jpg, .heic] + (ImageOps.canWriteAVIF ? [.avif] : []) + [.tiff, .pdf]).map { t in
                item(t) { url, _ in [try ImageOps.convert(url, to: t)] }
            }
        case .video:
            return MediaTarget.video.map { m in item(m.target) { url, p in [try MediaOps.convert(url, to: m, progress: p)] } }
        case .audio:
            return MediaTarget.audio.map { m in item(m.target) { url, p in [try MediaOps.convert(url, to: m, progress: p)] } }
        case .pdf:
            return [
                item(.png) { url, p in try DocOps.pdfToImages(url, to: .png, progress: p) },
                item(.jpg) { url, p in try DocOps.pdfToImages(url, to: .jpg, progress: p) },
                item(DocTarget.txt.target) { url, _ in [try DocOps.pdfToText(url)] },
                item(DocTarget.docx.target) { url, _ in [try DocOps.pdfToRich(url, to: .docx)] },
                item(DocTarget.rtf.target) { url, _ in [try DocOps.pdfToRich(url, to: .rtf)] },
            ]
        case .document:
            return [DocTarget.docx, .pdf, .txt, .rtf, .html, .odt].map { d in
                item(d.target) { url, _ in [try DocOps.convertDocument(url, to: d)] }
            }
        case .other:
            return []
        }
    }

    // MARK: Cmd: tools

    private static func tools(_ kind: FileKind) -> [WheelItem] {
        let compress = WheelItem(id: "compress", title: tr("ضغط", "Compress"), symbol: "arrow.down.right.and.arrow.up.left",
                                 action: .window { ToolWindows.compress($0, kind: kind) })
        switch kind {
        case .image:
            return [
                compress,
                WheelItem(id: "crop", title: tr("قص", "Crop"), symbol: "crop", maxCount: 1, action: .window { ToolWindows.crop($0[0]) }),
                WheelItem(id: "rotate", title: tr("تدوير", "Rotate"), symbol: "rotate.right",
                          action: .perFile(tr("تدوير", "Rotating")) { url, _ in [try ImageOps.rotate(url)] }),
                WheelItem(id: "strip", title: tr("بدون بيانات", "No Metadata"), symbol: "eye.slash",
                          action: .perFile(tr("حذف البيانات", "Removing metadata")) { url, _ in [try ImageOps.stripMetadata(url)] }),
                WheelItem(id: "merge", title: tr("دمج PDF", "Merge PDF"), symbol: "doc.on.doc", minCount: 2,
                          action: .together(tr("دمج في PDF", "Merging into PDF")) { urls, _ in [try ImageOps.mergeToPDF(urls)] }),
            ]
        case .video:
            return [
                compress,
                WheelItem(id: "trim", title: tr("قص", "Trim"), symbol: "scissors", maxCount: 1, action: .window { ToolWindows.trim($0[0]) }),
                WheelItem(id: "rotate", title: tr("تدوير", "Rotate"), symbol: "rotate.right",
                          accepts: { MediaOps.rotatable.contains(Kinds.ext($0)) },
                          action: .perFile(tr("تدوير", "Rotating")) { url, _ in [try MediaOps.rotateVideo(url)] }),
                WheelItem(id: "strip", title: tr("بدون بيانات", "No Metadata"), symbol: "eye.slash",
                          action: .perFile(tr("حذف البيانات", "Removing metadata")) { url, _ in [try MediaOps.stripMetadata(url, audioOnly: false)] }),
            ]
        case .audio:
            return [
                compress,
                WheelItem(id: "trim", title: tr("قص", "Trim"), symbol: "scissors", maxCount: 1, action: .window { ToolWindows.trim($0[0]) }),
                WheelItem(id: "strip", title: tr("بدون بيانات", "No Metadata"), symbol: "eye.slash",
                          action: .perFile(tr("حذف البيانات", "Removing metadata")) { url, _ in [try MediaOps.stripMetadata(url, audioOnly: true)] }),
            ]
        case .pdf:
            return [
                WheelItem(id: "compress", title: tr("ضغط", "Compress"), symbol: "arrow.down.right.and.arrow.up.left",
                          action: .perFile(tr("ضغط PDF", "Compressing PDF")) { url, _ in [try DocOps.compressPDF(url)] }),
                WheelItem(id: "merge", title: tr("دمج", "Merge"), symbol: "doc.on.doc", minCount: 2,
                          action: .together(tr("دمج PDF", "Merging PDFs")) { urls, _ in [try DocOps.mergePDFs(urls)] }),
                WheelItem(id: "strip", title: tr("بدون بيانات", "No Metadata"), symbol: "eye.slash",
                          action: .perFile(tr("حذف البيانات", "Removing metadata")) { url, _ in [try DocOps.stripPDF(url)] }),
            ]
        case .document, .other:
            return []
        }
    }

    // MARK: Ctrl: actions (any files or folders)

    private static var actions: [WheelItem] { [
        WheelItem(id: "airdrop", title: "AirDrop", symbol: "dot.radiowaves.left.and.right", action: .now(Actions.airDrop)),
        WheelItem(id: "path", title: tr("نسخ المسار", "Copy Path"), symbol: "link", action: .now(Actions.copyPath)),
        WheelItem(id: "move", title: tr("نقل", "Move"), symbol: "folder", action: .now(Actions.move)),
        WheelItem(id: "terminal", title: tr("الطرفية", "Terminal"), symbol: "terminal", action: .now(Actions.terminal)),
        WheelItem(id: "float", title: tr("تعويم", "Float"), symbol: "pin", action: .now(Actions.float)),
    ] }
}

/// Starts a segment's work after a drop.
enum Runner {
    static func perform(_ item: WheelItem, files: [URL]) {
        let use = item.usable(files)
        guard !use.isEmpty else { return }
        Log.write("run \(item.id) x\(use.count)")
        switch item.action {
        case .perFile(let title, let work): Jobs.perFile(title, files: use, work)
        case .together(let title, let work): Jobs.together(title, files: use, work)
        case .window(let open): open(use)
        case .now(let act): act(use)
        }
    }

    /// Same work without the HUD, for the command-line test mode.
    static func runSync(_ item: WheelItem, files: [URL]) throws -> [URL] {
        let use = item.usable(files)
        switch item.action {
        case .perFile(_, let work): return try use.flatMap { try work($0) { _ in } }
        case .together(_, let work): return try work(use) { _ in }
        case .window, .now: throw OpError.failed("this item needs the app's UI")
        }
    }
}
