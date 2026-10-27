import AppKit
import UniformTypeIdentifiers

final class EditorWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    // Remembered across windows so each new capture starts with your last style.
    private static var lastTool: Tool = .arrow
    private static var lastColor = Palette.colors[0]
    private static var lastSize = 1
    private static var lastFormat: UTType = .png

    private static let toolbarHeight: CGFloat = 40
    private static let bottomHeight: CGFloat = 30

    let canvas: CanvasView
    var onClose: ((EditorWindowController) -> Void)?

    private let rail = ToolRail()
    private let cropButtons = NSStackView()
    private let zoomLabel = NSTextField(labelWithString: "")
    private let nameField = NSTextField(string: "")
    private let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let dimsLabel = NSTextField(labelWithString: "")
    private var dragView: DragOutView!
    private var baseName: String
    private var format: UTType = EditorWindowController.lastFormat

    init(state: DocState, name: String? = nil) {
        canvas = CanvasView(state: state)
        baseName = name ?? ImageFiles.defaultName()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Skitch Redux"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = SkitchLook.chrome
        // Skitch's chrome is light-only; the hard-coded greys assume it.
        window.appearance = NSAppearance(named: .aqua)
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        buildUI()
        canvas.onSelectionChange = { [weak self] a in self?.syncStyle(from: a) }
        canvas.onCropChange = { [weak self] cropping in self?.cropButtons.isHidden = !cropping }
        canvas.onStateChange = { [weak self] in self?.updateInfo() }
        canvas.onToolRequest = { [weak self] t in self?.select(tool: t) }
        rail.onSelectTool = { [weak self] t in
            self?.select(tool: t)
            self?.window?.makeFirstResponder(self?.canvas)
        }
        rail.colorButton.menuProvider = { [weak self] in self?.colorMenu() }
        rail.sizeButton.menuProvider = { [weak self] in self?.sizeMenu() }

        select(tool: Self.lastTool == .crop ? .arrow : Self.lastTool)
        pick(color: Self.lastColor)
        pick(size: Self.lastSize)
        sizeWindowToFit()
        updateInfo()
        window.makeFirstResponder(canvas)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Layout

    private func buildUI() {
        guard let window, let content = window.contentView else { return }
        let titleHeight = window.frame.height - window.contentLayoutRect.height

        // Top: title bar area + the Screen Snap row.
        let top = ChromeBar(hairline: .bottom)
        let snap = SnapButton()
        snap.onSnap = { NSApp.sendAction(#selector(AppDelegate.captureRegion(_:)), to: nil, from: nil) }
        snap.onMenu = { SnapMenu.show(from: $0) }
        let share = chromeIconButton("square.and.arrow.up", tip: "Share…", target: self, action: #selector(share(_:)))
        let trash = chromeIconButton("trash", tip: "Discard this snap", target: self, action: #selector(discard(_:)))
        let divider = NSBox()
        divider.boxType = .separator
        let right = NSStackView(views: [share, divider, trash])
        right.spacing = 12

        let apply = NSButton(title: "Crop", target: self, action: #selector(applyCrop))
        apply.keyEquivalent = "\r"
        apply.bezelColor = .controlAccentColor
        apply.controlSize = .small
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelCrop))
        cancel.controlSize = .small
        cropButtons.setViews([cancel, apply], in: .leading)
        cropButtons.isHidden = true

        for v in [snap, right, cropButtons] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            top.addSubview(v)
        }

        // Bottom: zoom, name, format, drag tab, dimensions.
        let bottom = ChromeBar(hairline: .top)
        zoomLabel.font = .systemFont(ofSize: 11)
        zoomLabel.textColor = SkitchLook.text
        zoomLabel.toolTip = "Zoom (the image is scaled to fit the window)"

        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.font = .systemFont(ofSize: 11, weight: .semibold)
        nameField.textColor = SkitchLook.text
        nameField.stringValue = baseName
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.cell?.isScrollable = true
        nameField.toolTip = "Name used when dragging or saving — click to rename"
        nameField.delegate = self
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameField.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        formatPopup.addItems(withTitles: [".png", ".jpg"])
        formatPopup.isBordered = false
        formatPopup.font = .systemFont(ofSize: 11)
        formatPopup.controlSize = .small
        formatPopup.selectItem(at: format == .jpeg ? 1 : 0)
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)
        formatPopup.refusesFirstResponder = true

        dimsLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        dimsLabel.textColor = SkitchLook.text

        dragView = DragOutView(state: { [weak self] in self?.canvas.state ?? DocState(image: Self.emptyImage, size: .zero) },
                               format: { [weak self] in self?.format ?? .png },
                               name: { [weak self] in self?.baseName ?? ImageFiles.defaultName() })

        let left = NSStackView(views: [zoomLabel, nameField, formatPopup])
        left.spacing = 14
        left.setCustomSpacing(4, after: nameField)
        for v in [left, dragView!, dimsLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bottom.addSubview(v)
        }

        for v in [top, bottom, rail, canvas] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }

        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            top.heightAnchor.constraint(equalToConstant: titleHeight + Self.toolbarHeight),

            snap.centerXAnchor.constraint(equalTo: top.centerXAnchor),
            snap.centerYAnchor.constraint(equalTo: top.bottomAnchor, constant: -Self.toolbarHeight / 2),
            right.trailingAnchor.constraint(equalTo: top.trailingAnchor, constant: -16),
            right.centerYAnchor.constraint(equalTo: snap.centerYAnchor),
            divider.heightAnchor.constraint(equalToConstant: 18),
            cropButtons.trailingAnchor.constraint(equalTo: right.leadingAnchor, constant: -24),
            cropButtons.centerYAnchor.constraint(equalTo: snap.centerYAnchor),

            rail.topAnchor.constraint(equalTo: top.bottomAnchor),
            rail.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            rail.leadingAnchor.constraint(equalTo: content.leadingAnchor),

            canvas.topAnchor.constraint(equalTo: top.bottomAnchor),
            canvas.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bottom.heightAnchor.constraint(equalToConstant: Self.bottomHeight),

            left.leadingAnchor.constraint(equalTo: bottom.leadingAnchor, constant: 14),
            left.centerYAnchor.constraint(equalTo: bottom.centerYAnchor, constant: 0.5),
            left.trailingAnchor.constraint(lessThanOrEqualTo: dragView.leadingAnchor, constant: -12),
            nameField.widthAnchor.constraint(lessThanOrEqualToConstant: 260),
            nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
            dragView.centerXAnchor.constraint(equalTo: bottom.centerXAnchor),
            dragView.topAnchor.constraint(equalTo: bottom.topAnchor),
            dragView.widthAnchor.constraint(equalToConstant: 160),
            dragView.heightAnchor.constraint(equalToConstant: Self.bottomHeight),
            dimsLabel.trailingAnchor.constraint(equalTo: bottom.trailingAnchor, constant: -14),
            dimsLabel.centerYAnchor.constraint(equalTo: left.centerYAnchor),
        ])
    }

    private static let emptyImage: CGImage = {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }()

    private func sizeWindowToFit() {
        guard let window else { return }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let titleHeight = window.frame.height - window.contentLayoutRect.height
        let img = canvas.state.size
        let extraW = 56 + 2 * CanvasView.margin
        let extraH = titleHeight + Self.toolbarHeight + Self.bottomHeight + 2 * CanvasView.margin
        let w = min(max(img.width + extraW, window.minSize.width), visible.width * 0.9)
        let h = min(max(img.height + extraH, window.minSize.height), visible.height * 0.9)
        window.setFrame(NSRect(x: visible.midX - w / 2, y: visible.midY - h / 2, width: w, height: h), display: false)
    }

    private func updateInfo() {
        let s = canvas.state
        dimsLabel.stringValue = "\(Int(s.size.width.rounded())) x \(Int(s.size.height.rounded()))"
        dimsLabel.toolTip = "\(s.image.width) × \(s.image.height) pixels"
        updateZoom()
        dragView?.needsDisplay = true
    }

    private func updateZoom() {
        zoomLabel.stringValue = "\(Int((canvas.zoom * 100).rounded()))%"
    }

    func windowDidResize(_ notification: Notification) {
        updateZoom()
    }

    // MARK: - Style controls

    func select(tool: Tool) {
        canvas.tool = tool
        rail.select(tool)
        Self.lastTool = tool
    }

    private func pick(color: NSColor) {
        canvas.setColor(color)
        Self.lastColor = color
        rail.colorButton.content = .color(color)
    }

    private func pick(size: Int) {
        canvas.setSize(size)
        Self.lastSize = size
        rail.sizeButton.content = .size(size)
    }

    private func syncStyle(from a: Annotation?) {
        guard let a else { return }
        // Keep drawing with the selected annotation's style, like Skitch did.
        canvas.setColor(a.color)
        canvas.setSize(a.size)
        rail.colorButton.content = .color(a.color)
        rail.sizeButton.content = .size(a.size)
    }

    private func colorMenu() -> NSMenu {
        let menu = NSMenu()
        let current = canvas.currentColor
        for (color, name) in zip(Palette.colors, Palette.colorNames) {
            menu.addItem(ClosureMenuItem(name, image: SkitchLook.swatch(color), checked: color == current) { [weak self] in
                self?.pick(color: color)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Other…") { [weak self] in
            guard let self else { return }
            let panel = NSColorPanel.shared
            panel.color = current
            panel.setTarget(self)
            panel.setAction(#selector(self.colorPanelChanged(_:)))
            panel.orderFront(nil)
        })
        return menu
    }

    private func sizeMenu() -> NSMenu {
        let menu = NSMenu()
        for (i, name) in Palette.sizeTitles.enumerated() {
            menu.addItem(ClosureMenuItem(name, image: SkitchLook.lineWeight(i), checked: i == canvas.currentSize) { [weak self] in
                self?.pick(size: i)
            })
        }
        return menu
    }

    @objc private func colorPanelChanged(_ sender: NSColorPanel) {
        pick(color: sender.color)
    }

    @objc private func formatChanged() {
        format = formatPopup.indexOfSelectedItem == 1 ? .jpeg : .png
        Self.lastFormat = format
        dragView.needsDisplay = true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            nameField.stringValue = baseName
        } else {
            baseName = name
        }
        window?.makeFirstResponder(canvas)
    }

    @objc private func applyCrop() { canvas.applyCrop() }
    @objc private func cancelCrop() { canvas.cancelCrop() }

    // MARK: - Output

    @objc func copyImage() {
        ImageFiles.copyToPasteboard(canvas.state)
    }

    @objc func saveDocument(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format]
        panel.nameFieldStringValue = baseName + (format == .jpeg ? ".jpg" : ".png")
        panel.canSelectHiddenExtension = true

        let formatMenu = NSPopUpButton(frame: .zero, pullsDown: false)
        formatMenu.addItems(withTitles: ["PNG", "JPEG"])
        formatMenu.selectItem(at: format == .jpeg ? 1 : 0)
        let label = NSTextField(labelWithString: "Format:")
        let accessory = NSStackView(views: [label, formatMenu])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = accessory
        let formatHandler = FormatHandler(panel: panel)
        formatMenu.target = formatHandler
        formatMenu.action = #selector(FormatHandler.changed(_:))

        panel.beginSheetModal(for: window) { [weak self] response in
            _ = formatHandler
            guard response == .OK, let self, let url = panel.url else { return }
            let type: UTType = formatMenu.indexOfSelectedItem == 1 ? .jpeg : .png
            guard let data = ImageFiles.encode(self.canvas.state, as: type) else { NSSound.beep(); return }
            do {
                try data.write(to: url)
                window.representedURL = url
                self.baseName = url.deletingPathExtension().lastPathComponent
                self.nameField.stringValue = self.baseName
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        saveDocument(sender)
    }

    @objc private func share(_ sender: NSButton) {
        guard let data = ImageFiles.encode(canvas.state, as: format) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(baseName + (format == .jpeg ? ".jpg" : ".png"))
        try? data.write(to: url)
        NSSharingServicePicker(items: [url]).show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    @objc private func discard(_ sender: Any?) {
        window?.performClose(sender)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }
}

/// Swaps the save panel's allowed type when the format popup changes.
private final class FormatHandler: NSObject {
    weak var panel: NSSavePanel?
    init(panel: NSSavePanel) { self.panel = panel }

    @objc func changed(_ sender: NSPopUpButton) {
        panel?.allowedContentTypes = [sender.indexOfSelectedItem == 1 ? .jpeg : .png]
    }
}
