import AppKit
import ServiceManagement
import SwiftUI

// Test modes, so the work and the drawing can be checked without dragging:
//   Sahba --run <convert|tools> <item-id> <files...>      e.g. --run convert png photo.heic
//   Sahba --op compress <file> <0.1-0.9> | crop <file> <x> <y> <w> <h> | trim <file> <start> <end>
//   Sahba --snapshot <out.png> [--mode convert|tools|actions] [--kind image|video|audio|pdf|document|other]
//                              [--files N] [--hover I]
//   Sahba --snapshot-ui <compress|crop> <file> <out.png>
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--lang"), i + 1 < args.count {
    L10n.override = args[i + 1] == "en" ? .english : .arabic
}
if args.contains("--version") { print(CLI.version); exit(0) }
if args.contains("--doctor") { exit(CLI.doctor()) }
if args.contains("--unregister-login") {
    if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
    exit(0)
}
if let i = args.firstIndex(of: "--run") { exit(CLI.run(Array(args.dropFirst(i + 1)))) }
if let i = args.firstIndex(of: "--op") { exit(CLI.op(Array(args.dropFirst(i + 1)))) }
if let i = args.firstIndex(of: "--snapshot") { exit(CLI.snapshot(Array(args.dropFirst(i + 1)))) }
if let i = args.firstIndex(of: "--snapshot-ui") { exit(MainActor.assumeIsolated { CLI.snapshotUI(Array(args.dropFirst(i + 1))) }) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let wheel = WheelController()
    private let watcher = DragWatcher()
    private var lastName: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            NSApp.terminate(nil)
            return
        }
        setUpStatusItem()
        watcher.onShow = { [weak self] p, mode, urls in self?.wheel.show(at: p, mode: mode, files: urls) }
        watcher.onModeChange = { [weak self] mode in self?.wheel.setMode(mode) }
        watcher.onDragEnd = { [weak self] in self?.wheel.hideSoon() }
        Jobs.onOutputs = { [weak self] outputs in
            guard let self, let last = outputs.last else { return }
            self.lastName = last.lastPathComponent
            self.buildMenu()
        }
        if FF.ffmpeg == nil { Log.write("ffmpeg not found: video and audio need it") }
        watcher.start()
        Log.write("started")
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "circle.grid.cross", accessibilityDescription: "Sahba")
            ?? NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: "Sahba")
        image?.isTemplate = true
        statusItem.button?.image = image
        buildMenu()
    }

    /// Rebuilt whenever the language changes, so every line speaks the chosen language.
    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.userInterfaceLayoutDirection = L10n.arabic ? .rightToLeft : .leftToRight
        for line in [tr("اسحب ملف واضغط ⇧ للتحويل", "Drag a file and press ⇧ to convert"),
                     tr("وأنت فاتح العجلة: ⌘ أدوات، ⌃ إجراءات", "While the wheel is open: ⌘ Tools, ⌃ Actions")] {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        // A fresh item each time: one NSMenuItem can't sit in two menus.
        if let lastName {
            let lastItem = NSMenuItem(title: tr("آخر ملف: \(lastName)", "Last file: \(lastName)"), action: nil, keyEquivalent: "")
            lastItem.isEnabled = false
            menu.addItem(lastItem)
        }
        menu.addItem(.separator())

        let languages = NSMenu()
        for (lang, title) in [(Language.auto, tr("تلقائي (لغة الماك)", "Automatic (Mac language)")),
                              (.arabic, "العربية"), (.english, "English")] {
            let item = NSMenuItem(title: title, action: #selector(chooseLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = lang.rawValue
            item.state = L10n.setting == lang ? .on : .off
            languages.addItem(item)
        }
        let languageItem = NSMenuItem(title: tr("اللغة", "Language"), action: nil, keyEquivalent: "")
        languageItem.submenu = languages
        menu.addItem(languageItem)

        let loginItem = NSMenuItem(title: tr("تشغيل مع الماك", "Open at Login"), action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: tr("إنهاء سحبة", "Quit Sahba"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func chooseLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let lang = Language(rawValue: raw) else { return }
        L10n.setting = lang
        buildMenu()
        Log.write("language \(raw)")
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            HUD.shared.flash(tr("ما قدرت أغيّر التشغيل مع الماك", "Couldn't change Open at Login"), failed: true)
            Log.write("login item: \(error)")
        }
        buildMenu()
    }
}

enum CLI {
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    /// One screen of facts for bug reports: versions, chip, ffmpeg, HDR support.
    static func doctor() -> Int32 {
        func run(_ exe: String, _ a: [String]) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = a
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return "" }
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            return out
        }
        var hdr = "no (needs macOS 15)"
        if #available(macOS 15.0, *) { hdr = "yes" }
        let chip = run("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]).trimmingCharacters(in: .whitespacesAndNewlines)
        print("Sahba \(version)")
        let os = ProcessInfo.processInfo.operatingSystemVersion
        print("macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        print("chip: \(chip.isEmpty ? "unknown" : chip)")
        print("language: \(L10n.setting.rawValue) (\(L10n.arabic ? "Arabic" : "English"))")
        print("HDR photos: \(hdr)")
        var ok = true
        for (name, path) in [("ffmpeg", FF.ffmpeg), ("ffprobe", FF.ffprobe)] {
            if let path {
                let first = run(path, ["-version"]).split(separator: "\n").first.map(String.init) ?? "?"
                print("\(name): \(path) (\(first))")
            } else {
                print("\(name): MISSING (video and audio won't work)")
                ok = false
            }
        }
        return ok ? 0 : 1
    }

    static func run(_ a: [String]) -> Int32 {
        guard a.count >= 3, let mode = ["convert": WheelMode.convert, "tools": .tools][a[0]] else {
            fputs("usage: Sahba --run <convert|tools> <item-id> <files...>\n", stderr)
            return 2
        }
        let files = a.dropFirst(2).map { URL(fileURLWithPath: $0) }
        let kind = Kinds.groupKind(files)
        guard let item = Catalog.items(mode, kind).first(where: { $0.id == a[1] }) else {
            fputs("no item '\(a[1])' for \(kind) files\n", stderr)
            return 1
        }
        guard item.isEnabled(files) else {
            fputs("item '\(a[1])' is disabled for these files\n", stderr)
            return 1
        }
        do {
            for out in try Runner.runSync(item, files: files) { print(out.path) }
            return 0
        } catch {
            fputs("error: \((error as? LocalizedError)?.errorDescription ?? "\(error)")\n", stderr)
            return 1
        }
    }

    static func op(_ a: [String]) -> Int32 {
        guard a.count >= 2 else { return 2 }
        let url = URL(fileURLWithPath: a[1])
        let nums = a.dropFirst(2).compactMap(Double.init)
        do {
            let out: URL
            switch (a[0], Kinds.kind(url)) {
            case ("compress", .image): out = try ImageOps.compress(url, quality: nums.first ?? 0.6)
            case ("compress", .video): out = try MediaOps.compressVideo(url, fraction: nums.first ?? 0.5) { _ in }
            case ("compress", .audio): out = try MediaOps.compressAudio(url, fraction: nums.first ?? 0.5) { _ in }
            case ("crop", _) where nums.count == 4:
                out = try ImageOps.crop(url, rect: CGRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3]))
            case ("trim", _) where nums.count == 2:
                out = try MediaOps.trim(url, start: nums[0], end: nums[1]) { _ in }
            default:
                fputs("unknown op\n", stderr)
                return 2
            }
            print(out.path)
            return 0
        } catch {
            fputs("error: \((error as? LocalizedError)?.errorDescription ?? "\(error)")\n", stderr)
            return 1
        }
    }

    static func snapshot(_ a: [String]) -> Int32 {
        guard let path = a.first else { return 2 }
        func value(_ flag: String) -> String? {
            guard let i = a.firstIndex(of: flag), i + 1 < a.count else { return nil }
            return a[i + 1]
        }
        let view = WheelView(frame: NSRect(origin: .zero, size: WheelView.size))
        view.paintsBackdrop = true
        let mode = ["tools": WheelMode.tools, "actions": .actions][value("--mode") ?? ""] ?? .convert
        view.reset(mode: mode)
        if let k = value("--kind").flatMap(FileKind.init(rawValue:)) {
            let n = Int(value("--files") ?? "1") ?? 1
            view.setFiles(Array(repeating: URL(fileURLWithPath: "/nonexistent/\(k.sampleName)"), count: n), kind: k)
        }
        view.hovered = value("--hover").flatMap(Int.init)
        view.finishAnimations()
        return save(view, to: path)
    }

    @MainActor
    static func snapshotUI(_ a: [String]) -> Int32 {
        guard a.count >= 3 else { return 2 }
        let url = URL(fileURLWithPath: a[1])
        let content: AnyView
        switch a[0] {
        case "compress": content = AnyView(CompressView(files: [url], kind: Kinds.kind(url)) { _ in })
        case "crop":
            guard let image = ImageOps.orientedImage(url) else { return 1 }
            content = AnyView(CropView(image: image, name: url.lastPathComponent) { _ in })
        default: return 2
        }
        let renderer = ImageRenderer(content: content.environment(\.layoutDirection, L10n.arabic ? .rightToLeft : .leftToRight)
            .background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return 1 }
        return (try? png.write(to: URL(fileURLWithPath: a[2]))) != nil ? 0 : 1
    }

    private static func save(_ view: NSView, to path: String) -> Int32 {
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return 1 }
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]),
              (try? png.write(to: URL(fileURLWithPath: path))) != nil else { return 1 }
        print(path)
        return 0
    }
}
