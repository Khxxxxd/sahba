import AppKit

/// Notices when a file is being dragged anywhere on the Mac with Shift (or Ctrl) held,
/// and which wheel the held keys ask for while it is open.
///
/// No special permission is needed: mouse-down is a global mouse event, and the
/// button state, keys and drag pasteboard are polled only while the button is down.
/// Cmd on its own never opens the wheel, because Cmd-drag means "move" in Finder.
final class DragWatcher {
    var onShow: ((NSPoint, WheelMode) -> Void)?
    var onModeChange: ((WheelMode) -> Void)?
    var onDragEnd: (() -> Void)?

    private var monitor: Any?
    private var timer: Timer?
    /// The drag pasteboard's change count while the button was last up. A new drag bumps it.
    private var idleCount = NSPasteboard(name: .drag).changeCount
    private var shown = false
    private var mode: WheelMode = .convert
    /// Wheels whose keys are held, oldest press first. The newest press picks the wheel.
    private var pressed: [WheelMode] = []

    func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self] _ in
            self?.watch()
        }
    }

    private func watch() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 40, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    private func tick() {
        if NSEvent.pressedMouseButtons & 1 == 0 {
            timer?.invalidate()
            timer = nil
            idleCount = NSPasteboard(name: .drag).changeCount
            if shown {
                shown = false
                onDragEnd?()
            }
            return
        }
        let flags = NSEvent.modifierFlags
        let held = WheelMode.held(flags)
        if shown {
            // The last key pressed picks the wheel. Letting go of it goes back to a key still held;
            // letting go of everything keeps the current wheel.
            pressed.removeAll { !held.contains($0) }
            pressed += held.filter { !pressed.contains($0) }
            if let m = pressed.last, m != mode {
                mode = m
                onModeChange?(m)
            }
            return
        }
        guard flags.contains(.shift) || flags.contains(.control) else { return }
        // A new drag writes to the drag pasteboard, so its change count moves.
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != idleCount, pb.types?.contains(.fileURL) == true else { return }
        shown = true
        pressed = held
        mode = held.last ?? .convert
        onShow?(NSEvent.mouseLocation, mode)
    }
}
