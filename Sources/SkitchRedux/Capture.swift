import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

enum CaptureMode {
    case region, window, fullscreen
    /// Full screen after a 5 second countdown, so menus and hover states can be set up.
    case timed
}

/// Captures in-process with ScreenCaptureKit. Shelling out to `/usr/sbin/screencapture` looked
/// simpler, but on recent macOS the child process doesn't inherit our Screen Recording grant and
/// silently returns a blank image.
@MainActor
enum ScreenCapture {
    private static var active: SelectionController?

    static func capture(_ mode: CaptureMode, completion: @escaping (DocState?) -> Void) {
        Task { @MainActor in
            switch mode {
            case .fullscreen:
                completion(await fullscreen())
            case .timed:
                try? await Task.sleep(for: .seconds(5))
                completion(await fullscreen())
            case .region, .window:
                guard let snaps = await snapshotAllScreens(), !snaps.isEmpty else { return completion(nil) }
                let controller = SelectionController(snaps: snaps, windowMode: mode == .window,
                                                     windows: onScreenWindows()) { result in
                    active = nil
                    completion(result)
                }
                active = controller
                controller.begin()
            }
        }
    }

    /// The screen under the mouse pointer.
    private static func fullscreen() async -> DocState? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen, let snap = await snapshot(screen) else { return nil }
        return DocState(image: snap.image, size: screen.frame.size)
    }

    struct ScreenSnap {
        let screen: NSScreen
        let image: CGImage
    }

    private static func snapshotAllScreens() async -> [ScreenSnap]? {
        var snaps: [ScreenSnap] = []
        for screen in NSScreen.screens {
            if let snap = await snapshot(screen) { snaps.append(snap) }
        }
        return snaps
    }

    private static func snapshot(_ screen: NSScreen) async -> ScreenSnap? {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
        let config = SCStreamConfiguration()
        config.width = Int(screen.frame.width * screen.backingScaleFactor)
        config.height = Int(screen.frame.height * screen.backingScaleFactor)
        config.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        return ScreenSnap(screen: screen, image: image)
    }

    struct WindowInfo {
        let id: CGWindowID
        /// In AppKit global coordinates (bottom-left origin).
        let frame: CGRect
    }

    /// Ordinary app windows, front to back, excluding our own.
    private static func onScreenWindows() -> [WindowInfo] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        let ourPID = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  info[kCGWindowOwnerPID as String] as? pid_t != ourPID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let cg = CGRect(dictionaryRepresentation: dict),
                  cg.width > 20, cg.height > 20 else { return nil }
            return WindowInfo(id: id, frame: CGRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height))
        }
    }

    /// Captures one window on its own, even if other windows overlap it.
    static func capture(window: WindowInfo) async -> DocState? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let scWindow = content.windows.first(where: { $0.windowID == window.id }) else { return nil }
        let scale = NSScreen.screens.first { $0.frame.intersects(window.frame) }?.backingScaleFactor ?? 2
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        let filter = SCContentFilter(desktopIndependentWindow: scWindow)
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        return DocState(image: image, size: window.frame.size)
    }
}

/// Skitch-style crosshair / window picker drawn over a frozen copy of every screen.
/// Drag to select an area, Space switches between area and window picking, Esc cancels.
@MainActor
final class SelectionController {
    private let snaps: [ScreenCapture.ScreenSnap]
    private let windows: [ScreenCapture.WindowInfo]
    private let completion: (DocState?) -> Void
    private var overlays: [NSWindow] = []
    private var monitor: Any?
    private var finished = false

    var windowMode: Bool { didSet { refresh() } }
    /// Drag rectangle or hovered window, in AppKit global coordinates.
    var dragStart: CGPoint?
    var current: CGPoint = .zero
    var hoveredWindow: ScreenCapture.WindowInfo?

    init(snaps: [ScreenCapture.ScreenSnap], windowMode: Bool, windows: [ScreenCapture.WindowInfo],
         completion: @escaping (DocState?) -> Void) {
        self.snaps = snaps
        self.windowMode = windowMode
        self.windows = windows
        self.completion = completion
    }

    var selection: CGRect? {
        guard let dragStart else { return nil }
        return CGRect(x: min(dragStart.x, current.x), y: min(dragStart.y, current.y),
                      width: abs(current.x - dragStart.x), height: abs(current.y - dragStart.y))
    }

    func begin() {
        for snap in snaps {
            let window = NSWindow(contentRect: snap.screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.isOpaque = true
            window.hasShadow = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = SelectionView(snap: snap, controller: self)
            window.setFrame(snap.screen.frame, display: false)
            overlays.append(window)
        }
        NSApp.activate()
        overlays.forEach { $0.orderFrontRegardless() }
        let mouse = NSEvent.mouseLocation
        (overlays.first { $0.frame.contains(mouse) } ?? overlays.first)?.makeKey()
        current = mouse
        updateHover()
        NSCursor.crosshair.push()
        // Keys go to the key overlay; a local monitor catches them whichever screen that is.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch Int(event.keyCode) {
            case kVK_Escape: self.finish(nil)
            case kVK_Space where self.dragStart == nil: self.windowMode.toggle()
            default: break
            }
            return nil
        }
    }

    func mouseMoved(to point: CGPoint) {
        current = point
        if windowMode { updateHover() }
        refresh()
    }

    func mouseDown(at point: CGPoint) {
        current = point
        if !windowMode { dragStart = point }
    }

    func mouseUp(at point: CGPoint) {
        current = point
        if windowMode {
            guard let window = hoveredWindow else { return finish(nil) }
            overlays.forEach { $0.orderOut(nil) }
            Task { @MainActor in self.finish(await ScreenCapture.capture(window: window)) }
            return
        }
        guard let rect = selection, rect.width >= 3, rect.height >= 3 else {
            dragStart = nil
            refresh()
            return
        }
        finish(crop(rect))
    }

    private func updateHover() {
        hoveredWindow = windows.first { $0.frame.contains(current) }
    }

    private func refresh() {
        overlays.forEach { $0.contentView?.needsDisplay = true }
    }

    /// Crops the frozen screen image under the selection's centre.
    private func crop(_ rect: CGRect) -> DocState? {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        guard let snap = snaps.first(where: { $0.screen.frame.contains(centre) }) ?? snaps.first else { return nil }
        let frame = snap.screen.frame
        let r = rect.intersection(frame)
        let scale = CGFloat(snap.image.width) / frame.width
        let pixelRect = CGRect(x: (r.minX - frame.minX) * scale, y: (frame.maxY - r.maxY) * scale,
                               width: r.width * scale, height: r.height * scale).integral
        guard let image = snap.image.cropping(to: pixelRect) else { return nil }
        return DocState(image: image, size: r.size)
    }

    private func finish(_ result: DocState?) {
        guard !finished else { return }
        finished = true
        if let monitor { NSEvent.removeMonitor(monitor) }
        NSCursor.pop()
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        completion(result)
    }
}

private final class SelectionView: NSView {
    private let snap: ScreenCapture.ScreenSnap
    private unowned let controller: SelectionController

    init(snap: ScreenCapture.ScreenSnap, controller: SelectionController) {
        self.snap = snap
        self.controller = controller
        super.init(frame: CGRect(origin: .zero, size: snap.screen.frame.size))
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func global(_ event: NSEvent) -> CGPoint { NSEvent.mouseLocation }
    private func local(_ rect: CGRect) -> CGRect { rect.offsetBy(dx: -snap.screen.frame.minX, dy: -snap.screen.frame.minY) }

    override func mouseMoved(with event: NSEvent) { controller.mouseMoved(to: global(event)) }
    override func mouseDown(with event: NSEvent) { controller.mouseDown(at: global(event)) }
    override func mouseDragged(with event: NSEvent) { controller.mouseMoved(to: global(event)) }
    override func mouseUp(with event: NSEvent) { controller.mouseUp(at: global(event)) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.draw(snap.image, in: bounds)
        let dim = NSColor.black.withAlphaComponent(0.25)

        if controller.windowMode {
            dim.setFill()
            bounds.fill()
            guard let window = controller.hoveredWindow else { return }
            let r = local(window.frame)
            // Show the window undimmed with a blue wash, like the system window picker.
            ctx.saveGState()
            ctx.clip(to: r)
            ctx.draw(snap.image, in: bounds)
            ctx.restoreGState()
            NSColor.systemBlue.withAlphaComponent(0.25).setFill()
            r.fill()
            return
        }

        guard let sel = controller.selection else { return }
        let r = local(sel)
        let path = NSBezierPath(rect: bounds)
        path.append(NSBezierPath(rect: r))
        path.windingRule = .evenOdd
        dim.setFill()
        path.fill()
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: r.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()

        // Size readout, as in Skitch.
        let label = "\(Int(sel.width)) × \(Int(sel.height))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attrs)
        var box = CGRect(x: r.maxX + 8, y: r.minY - size.height - 12, width: size.width + 12, height: size.height + 6)
        if box.maxX > bounds.maxX { box.origin.x = r.maxX - box.width }
        if box.minY < bounds.minY { box.origin.y = r.minY + 6 }
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        label.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3), withAttributes: attrs)
    }
}

/// Global hotkeys via Carbon — works without Accessibility permission.
final class HotKeyCenter {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private var refs: [EventHotKeyRef] = []

    func register(keyCode: Int, modifiers: Int, id: UInt32, handler: @escaping () -> Void) {
        Self.installHandlerIfNeeded()
        Self.handlers[id] = handler
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x534B_5452), id: id) // 'SKTR'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref { refs.append(ref) }
    }

    private static func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKeyCenter.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

