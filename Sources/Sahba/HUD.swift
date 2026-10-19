import AppKit
import SwiftUI

/// Background jobs with a small progress card at the top-right of the screen.
/// Quick jobs (under 0.6 s) finish silently; only slow ones and errors show up.
enum Jobs {
    static var onOutputs: (([URL]) -> Void)?

    static func perFile(_ title: String, files: [URL], _ work: @escaping (URL, @escaping (Double) -> Void) throws -> [URL]) {
        together(title, files: files) { files, progress in
            var outputs: [URL] = []
            var errors: [Error] = []
            for (i, file) in files.enumerated() {
                do {
                    outputs += try work(file) { p in progress((Double(i) + p) / Double(files.count)) }
                } catch {
                    errors.append(error)
                    Log.write("failed \(file.path): \(error)")
                }
            }
            if let first = errors.first {
                let msg = (first as? LocalizedError)?.errorDescription ?? "\(first)"
                throw OpError.failed(files.count > 1 ? tr("\(errors.count) من \(files.count) ما زبطت: \(msg)", "\(errors.count) of \(files.count) failed: \(msg)") : msg)
            }
            return outputs
        }
    }

    static func together(_ title: String, files: [URL], _ work: @escaping ([URL], @escaping (Double) -> Void) throws -> [URL]) {
        let id = HUD.shared.begin(title)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let outputs = try work(files) { p in HUD.shared.progress(id, p) }
                outputs.forEach { Log.write("output \($0.path)") }
                DispatchQueue.main.async {
                    let name = outputs.count == 1 ? outputs[0].lastPathComponent : tr("\(outputs.count) ملفات", "\(outputs.count) files")
                    HUD.shared.finish(id, title: tr("خلص: \(name)", "Done: \(name)"), failed: false)
                    onOutputs?(outputs)
                }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                Log.write("job failed \(title): \(msg)")
                DispatchQueue.main.async { HUD.shared.finish(id, title: tr("ما زبط: \(msg)", "Failed: \(msg)"), failed: true) }
            }
        }
    }
}

extension Color {
    /// The «ليل» palette's mint, shared by the HUD and the tool windows.
    static let sahbaMint = Color(red: 0.08, green: 0.72, blue: 0.61)
}

final class HUDModel: ObservableObject {
    enum State { case running, done, failed }
    struct Row: Identifiable {
        let id = UUID()
        var title: String
        var progress: Double = 0
        var state: State = .running
        var visible = false
    }
    @Published var rows: [Row] = []
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.rows.filter(\.visible)) { row in
                HStack(spacing: 12) {
                    icon(row.state)
                        .frame(width: 24, height: 24)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.title)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 240, alignment: .leading)

                            if row.state == .running && row.progress > 0 {
                                Spacer(minLength: 4)
                                Text("\(Int(row.progress * 100))%")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.sahbaAccent)
                            }
                        }

                        if row.state == .running {
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.12))
                                    .frame(width: 220, height: 5)
                                Capsule()
                                    .fill(
                                        LinearGradient(colors: [Theme.sahbaAccentHover, Theme.sahbaAccent],
                                                       startPoint: .leading, endPoint: .trailing)
                                    )
                                    .frame(width: max(5, 220 * CGFloat(min(max(row.progress, 0), 1))), height: 5)
                                    .animation(.spring(response: 0.25, dampingFraction: 0.8), value: row.progress)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            ZStack {
                Color(red: 0.08, green: 0.10, blue: 0.14).opacity(0.85)
                Rectangle().fill(.ultraThinMaterial)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LinearGradient(colors: [Color.white.opacity(0.32), Color.white.opacity(0.08)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1
                )
        )
        .shadow(color: Color.black.opacity(0.35), radius: 16, x: 0, y: 6)
        .environment(\.layoutDirection, L10n.arabic ? .rightToLeft : .leftToRight)
        .fixedSize()
    }

    @ViewBuilder private func icon(_ state: HUDModel.State) -> some View {
        switch state {
        case .running:
            ProgressView()
                .controlSize(.small)
                .tint(Theme.sahbaAccent)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.multicolor)
                .foregroundStyle(Color.green)
                .font(.system(size: 20))
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .symbolRenderingMode(.multicolor)
                .foregroundStyle(Color.red)
                .font(.system(size: 20))
        }
    }
}

final class HUD {
    static let shared = HUD()
    private let model = HUDModel()
    private lazy var host = NSHostingView(rootView: HUDView(model: model))
    private lazy var panel: NSPanel = {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.ignoresMouseEvents = true
        p.contentView = host
        return p
    }()

    func begin(_ title: String) -> UUID {
        let row = HUDModel.Row(title: title)
        model.rows.append(row)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, let i = self.index(row.id), self.model.rows[i].state == .running else { return }
            self.model.rows[i].visible = true
            self.refresh()
        }
        return row.id
    }

    func progress(_ id: UUID, _ p: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let i = self.index(id) else { return }
            self.model.rows[i].progress = p
        }
    }

    func finish(_ id: UUID, title: String, failed: Bool) {
        guard let i = index(id) else { return }
        if failed {
            model.rows[i].state = .failed
            model.rows[i].title = title
            model.rows[i].visible = true
            NSSound.beep()
            remove(id, after: 4)
        } else if model.rows[i].visible {
            model.rows[i].state = .done
            model.rows[i].title = title
            remove(id, after: 1.6)
        } else {
            model.rows.remove(at: i)
        }
        refresh()
    }

    /// A short confirmation, e.g. "انتسخ المسار".
    func flash(_ text: String, failed: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var row = HUDModel.Row(title: text)
            row.state = failed ? .failed : .done
            row.visible = true
            self.model.rows.append(row)
            self.remove(row.id, after: 1.6)
            self.refresh()
        }
    }

    private func index(_ id: UUID) -> Int? { model.rows.firstIndex { $0.id == id } }

    private func remove(_ id: UUID, after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let i = self.index(id) else { return }
            self.model.rows.remove(at: i)
            self.refresh()
        }
    }

    private func refresh() {
        // Let SwiftUI lay out the new rows first.
        DispatchQueue.main.async { [self] in
            guard model.rows.contains(where: \.visible) else { panel.orderOut(nil); return }
            host.layoutSubtreeIfNeeded()
            let size = host.fittingSize
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            guard let area = screen?.visibleFrame else { return }
            panel.setFrame(NSRect(x: area.maxX - size.width - 16, y: area.maxY - size.height - 10,
                                  width: size.width, height: size.height), display: true)
            panel.orderFrontRegardless()
        }
    }
}
