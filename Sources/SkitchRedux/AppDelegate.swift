import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var editors: [EditorWindowController] = []
    private var launcher: NSWindow?
    private var statusItem: NSStatusItem?
    private let hotKeys = HotKeyCenter()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMainMenu()
        buildStatusItem()
        registerHotKeys()
        if editors.isEmpty { showLauncher(nil) }
        // `--capture fullscreen|region|window` triggers a snap at launch (used for testing).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--capture"), i + 1 < args.count {
            let modes: [String: CaptureMode] = ["fullscreen": .fullscreen, "region": .region, "window": .window]
            if let mode = modes[args[i + 1]] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.capture(mode) }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { open(url: url) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showLauncher(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Actions

    @objc func captureRegion(_ sender: Any?) { capture(.region) }
    @objc func captureWindow(_ sender: Any?) { capture(.window) }
    @objc func captureFullscreen(_ sender: Any?) { capture(.fullscreen) }
    @objc func captureTimed(_ sender: Any?) { capture(.timed) }

    @objc func newBlank(_ sender: Any?) {
        // Drawn at 2x so annotations stay crisp on retina exports.
        let size = CGSize(width: 1200, height: 800)
        guard let ctx = CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        guard let image = ctx.makeImage() else { return }
        openEditor(DocState(image: image, size: size), name: "Blank")
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url: url) }
    }

    @objc func newFromClipboard(_ sender: Any?) {
        guard let state = ImageFiles.load(pasteboard: .general) else {
            NSSound.beep()
            return
        }
        openEditor(state)
    }

    @objc func showLauncher(_ sender: Any?) {
        if launcher == nil { launcher = makeLauncher() }
        NSApp.activate()
        launcher?.makeKeyAndOrderFront(nil)
    }

    private func open(url: URL) {
        guard let state = ImageFiles.load(url: url) else {
            let alert = NSAlert()
            alert.messageText = "Couldn’t open “\(url.lastPathComponent)”"
            alert.informativeText = "The file isn’t an image Skitch Redux can read."
            alert.runModal()
            return
        }
        let editor = openEditor(state, name: url.deletingPathExtension().lastPathComponent)
        editor.window?.representedURL = url
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    @discardableResult
    private func openEditor(_ state: DocState, name: String? = nil) -> EditorWindowController {
        let editor = EditorWindowController(state: state, name: name)
        editor.onClose = { [weak self] e in self?.editors.removeAll { $0 === e } }
        editors.append(editor)
        launcher?.orderOut(nil)
        NSApp.activate()
        editor.showWindow(nil)
        // Activation can be refused when a hotkey fired while another app was frontmost,
        // so make sure the new snap is on screen regardless.
        editor.window?.orderFrontRegardless()
        return editor
    }

    private func capture(_ mode: CaptureMode) {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            showScreenRecordingAlert()
            return
        }

        // Get our own windows out of the way for every kind of snap, as Skitch does, so they're
        // neither in the shot nor covering what you want to select. We only order them out rather
        // than hiding the app: a hidden app can't reliably reactivate itself afterwards, which
        // left the snap (and every other window) stuck out of sight.
        let stashed = NSApp.windows.filter { $0.isVisible && $0.level == .normal }
        let keyWindow = NSApp.keyWindow
        stashed.forEach { $0.orderOut(nil) }

        let run: @MainActor () -> Void = { [weak self] in
            ScreenCapture.capture(mode) { state in
                if let state {
                    // Without a working Screen Recording grant macOS hands back a blank image
                    // rather than an error, so treat that as a permission problem.
                    if Self.isBlank(state.image) {
                        stashed.forEach { $0.orderFrontRegardless() }
                        self?.showScreenRecordingAlert()
                        return
                    }
                    // The finished snap replaces the launcher, but other editors come back behind it.
                    stashed.filter { $0 !== self?.launcher }.forEach { $0.orderFrontRegardless() }
                    self?.openEditor(state)
                } else {
                    // Cancelled (Esc) or failed: put everything back as it was.
                    stashed.forEach { $0.orderFrontRegardless() }
                    keyWindow?.makeKeyAndOrderFront(nil)
                    if stashed.isEmpty { self?.showLauncher(nil) }
                    NSApp.activate()
                }
            }
        }
        if stashed.isEmpty {
            run()
        } else {
            // Give the window server a moment to take our windows off screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { run() }
        }
    }

    private func showScreenRecordingAlert() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = """
            macOS gave Skitch Redux a blank snap, which means it isn’t allowed to record the screen.

            In System Settings → Privacy & Security → Screen & System Audio Recording, remove any \
            existing Skitch Redux entry with the – button, add /Applications/Skitch Redux.app again, \
            then quit and reopen the app.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// True when every pixel of a small thumbnail is the same colour.
    private static func isBlank(_ image: CGImage) -> Bool {
        let side = 16
        var pixels = [UInt32](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                      bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return drawn && pixels.allSatisfy { $0 == pixels[0] }
    }

    // MARK: - Hotkeys & menus

    private func registerHotKeys() {
        let mods = cmdKey | controlKey
        hotKeys.register(keyCode: kVK_ANSI_5, modifiers: mods, id: 1) { [weak self] in self?.capture(.region) }
        hotKeys.register(keyCode: kVK_ANSI_6, modifiers: mods, id: 2) { [weak self] in self?.capture(.fullscreen) }
        hotKeys.register(keyCode: kVK_ANSI_7, modifiers: mods, id: 3) { [weak self] in self?.capture(.window) }
    }

    private func captureItems() -> [NSMenuItem] {
        [
            item("Crosshair Snapshot", #selector(captureRegion(_:)), "5", [.command, .control]),
            item("Window Snapshot", #selector(captureWindow(_:)), "7", [.command, .control]),
            item("Fullscreen Snapshot", #selector(captureFullscreen(_:)), "6", [.command, .control]),
            item("Timed Fullscreen Snapshot (5s)", #selector(captureTimed(_:)), "", []),
        ]
    }

    private func buildStatusItem() {
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: "Skitch Redux")
        let menu = NSMenu()
        captureItems().forEach(menu.addItem)
        menu.addItem(.separator())
        menu.addItem(item("Open Image…", #selector(openDocument(_:)), "", []))
        menu.addItem(item("New from Clipboard", #selector(newFromClipboard(_:)), "", []))
        menu.addItem(item("Show Skitch Redux", #selector(showLauncher(_:)), "", []))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Skitch Redux", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        status.menu = menu
        statusItem = status
    }

    private func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = self
        return i
    }

    private func buildMainMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About Skitch Redux", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Skitch Redux", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Skitch Redux", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(app, title: "Skitch Redux"))

        let file = NSMenu(title: "File")
        file.addItem(item("New from Clipboard", #selector(newFromClipboard(_:)), "n", .command))
        file.addItem(item("New Blank", #selector(newBlank(_:)), "n", [.command, .shift]))
        file.addItem(item("Open…", #selector(openDocument(_:)), "o", .command))
        file.addItem(.separator())
        captureItems().forEach(file.addItem)
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Save…", action: #selector(EditorWindowController.saveDocument(_:)), keyEquivalent: "s")
        let saveAs = file.addItem(withTitle: "Save As…", action: #selector(EditorWindowController.saveDocumentAs(_:)), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        main.addItem(submenu(file, title: "File"))

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu(edit, title: "Edit"))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        main.addItem(submenu(window, title: "Window"))
        NSApp.windowsMenu = window

        return main
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    // MARK: - Launcher

    private func makeLauncher() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Skitch Redux"
        window.isReleasedWhenClosed = false

        func button(_ title: String, _ symbol: String, _ action: Selector, _ hint: String) -> NSView {
            let b = NSButton(title: "  " + title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!,
                             target: self, action: action)
            b.imagePosition = .imageLeading
            b.controlSize = .large
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 220).isActive = true
            let h = NSTextField(labelWithString: hint)
            h.textColor = .secondaryLabelColor
            h.font = .systemFont(ofSize: 11)
            return NSStackView(views: [b, h])
        }

        let stack = NSStackView(views: [
            button("Crosshair Snapshot", "plus.viewfinder", #selector(captureRegion(_:)), "⌃⌘5"),
            button("Window Snapshot", "macwindow", #selector(captureWindow(_:)), "⌃⌘7"),
            button("Fullscreen Snapshot", "display", #selector(captureFullscreen(_:)), "⌃⌘6"),
            button("Open Image…", "photo", #selector(openDocument(_:)), "⌘O"),
            button("New from Clipboard", "doc.on.clipboard", #selector(newFromClipboard(_:)), "⌘N"),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)
        window.contentView = stack
        window.center()
        return window
    }
}
