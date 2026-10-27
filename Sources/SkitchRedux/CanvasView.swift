import AppKit

final class CanvasView: NSView, NSTextFieldDelegate {
    private(set) var state: DocState {
        didSet {
            needsDisplay = true
            onStateChange?()
        }
    }

    var tool: Tool = .arrow {
        didSet { toolChanged(from: oldValue) }
    }
    private(set) var currentColor = Palette.colors[0]
    private(set) var currentSize = 1

    private(set) var selectedID: UUID? {
        didSet {
            guard oldValue != selectedID else { return }
            needsDisplay = true
            onSelectionChange?(selected)
        }
    }
    var selected: Annotation? { state.index(of: selectedID).map { state.annotations[$0] } }

    var onSelectionChange: ((Annotation?) -> Void)?
    var onCropChange: ((Bool) -> Void)?
    var onStateChange: (() -> Void)?
    var onToolRequest: ((Tool) -> Void)?

    private enum Drag {
        case none
        case creating(Annotation)
        case moving(last: CGPoint)
        case handle(Int)
        case cropping(origin: CGPoint)
    }
    private var drag = Drag.none
    private var stateBeforeDrag: DocState?
    private var toolBeforeCrop: Tool = .arrow

    private(set) var cropRect: CGRect? {
        didSet {
            needsDisplay = true
            if (oldValue == nil) != (cropRect == nil) { onCropChange?(cropRect != nil) }
        }
    }

    private var textField: NSTextField?
    private var textOrigin = CGPoint.zero
    private var textColor = Palette.colors[0]
    private var textSize = 1
    private var editingTextID: UUID?

    init(state: DocState) {
        self.state = state
        super.init(frame: .zero)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Geometry (view ⇄ image points)

    /// White space kept around the page, as in Skitch.
    static let margin: CGFloat = 32

    private var scale: CGFloat {
        guard state.size.width > 0, state.size.height > 0 else { return 1 }
        let w = max(bounds.width - 2 * Self.margin, 1), h = max(bounds.height - 2 * Self.margin, 1)
        return min(1, w / state.size.width, h / state.size.height)
    }

    /// Current display scale of the image (1 = actual size).
    var zoom: CGFloat { scale }

    private var imageOrigin: CGPoint {
        CGPoint(x: floor((bounds.width - state.size.width * scale) / 2),
                y: floor((bounds.height - state.size.height * scale) / 2))
    }

    private func toImage(_ p: CGPoint) -> CGPoint {
        let o = imageOrigin, s = scale
        return CGPoint(x: (p.x - o.x) / s, y: (p.y - o.y) / s)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        let o = imageOrigin, s = scale
        return CGPoint(x: p.x * s + o.x, y: p.y * s + o.y)
    }

    private func toView(_ r: CGRect) -> CGRect {
        let o = toView(r.origin)
        return CGRect(x: o.x, y: o.y, width: r.width * scale, height: r.height * scale)
    }

    private func clampToImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), state.size.width), y: min(max(p.y, 0), state.size.height))
    }

    private func imagePoint(_ event: NSEvent) -> CGPoint {
        toImage(convert(event.locationInWindow, from: nil))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
        layoutTextField()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let o = imageOrigin, s = scale
        // Page shadow, like Skitch's paper sitting on the canvas.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 7, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(toView(state.bounds))
        ctx.restoreGState()

        ctx.saveGState()
        ctx.translateBy(x: o.x, y: o.y)
        ctx.scaleBy(x: s, y: s)
        ctx.clip(to: state.bounds)
        Renderer.draw(state, hiding: editingTextID, in: ctx)
        if case .creating(let a) = drag {
            Renderer.draw(a, on: state, in: ctx)
        }
        ctx.restoreGState()

        drawSelection()
        drawCropOverlay()
    }

    private func drawSelection() {
        guard let a = selected, tool != .crop, editingTextID == nil else { return }
        if a.kind != .arrow && a.kind != .line {
            let outline = NSBezierPath(rect: toView(a.bounds).insetBy(dx: -4, dy: -4))
            outline.lineWidth = 1
            outline.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            outline.stroke()
        }
        for h in a.handles {
            let c = toView(h)
            let dot = NSBezierPath(ovalIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10))
            NSColor.white.setFill()
            dot.fill()
            dot.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            dot.stroke()
        }
    }

    private func drawCropOverlay() {
        guard let r = cropRect else { return }
        let vr = toView(r)
        let dim = NSBezierPath(rect: toView(state.bounds))
        dim.append(NSBezierPath(rect: vr))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.5).setFill()
        dim.fill()

        let border = NSBezierPath(rect: vr)
        border.lineWidth = 1
        border.setLineDash([5, 4], count: 2, phase: 0)
        NSColor.white.setStroke()
        border.stroke()

        let px = state.pixelScale
        let label = "\(Int((r.width * px).rounded())) × \(Int((r.height * px).rounded())) — Return to crop, Esc to cancel"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (label as NSString).size(withAttributes: attrs)
        var bg = CGRect(x: vr.minX, y: vr.maxY + 6, width: size.width + 12, height: size.height + 6)
        if bg.maxY > bounds.maxY { bg.origin.y = vr.maxY - bg.height - 6 }
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 4, yRadius: 4).fill()
        (label as NSString).draw(at: CGPoint(x: bg.minX + 6, y: bg.minY + 3), withAttributes: attrs)
    }

    override func resetCursorRects() {
        let cursor: NSCursor = switch tool {
        case .select: .arrow
        case .text: .iBeam
        default: .crosshair
        }
        addCursorRect(visibleRect, cursor: cursor)
    }

    // MARK: - Mouse

    private var hitTolerance: CGFloat { 4 / scale }

    private func topmost(at p: CGPoint, interior: Bool) -> Annotation? {
        state.annotations.reversed().first { $0.hit(p, tolerance: hitTolerance, interior: interior) }
    }

    private func handleIndex(at p: CGPoint, of a: Annotation) -> Int? {
        let tol = 7 / scale
        return a.handles.firstIndex { hypot($0.x - p.x, $0.y - p.y) <= tol }
    }

    override func mouseDown(with event: NSEvent) {
        let wasEditingText = textField != nil
        commitText()
        window?.makeFirstResponder(self)

        let p = imagePoint(event)
        stateBeforeDrag = state
        drag = .none

        if tool == .crop {
            let c = clampToImage(p)
            drag = .cropping(origin: c)
            cropRect = CGRect(origin: c, size: .zero)
            return
        }

        if let a = selected, let h = handleIndex(at: p, of: a) {
            drag = .handle(h)
            return
        }

        if tool == .text {
            if let hit = topmost(at: p, interior: true), hit.kind == .text {
                selectedID = hit.id
                beginTextEditing(existing: hit)
            } else if !wasEditingText {
                selectedID = nil
                beginTextEditing(at: p)
            }
            return
        }

        if let hit = topmost(at: p, interior: tool == .select) {
            selectedID = hit.id
            if event.clickCount == 2, hit.kind == .text {
                beginTextEditing(existing: hit)
            } else {
                drag = .moving(last: p)
            }
            return
        }

        selectedID = nil
        guard let kind = tool.kind else { return }
        drag = .creating(Annotation(kind: kind, start: p, color: currentColor, size: currentSize))
    }

    override func mouseDragged(with event: NSEvent) {
        let p = imagePoint(event)
        let shift = event.modifierFlags.contains(.shift)

        switch drag {
        case .none:
            break
        case .creating(var a):
            if a.kind.isFreehand {
                a.points.append(p)
                a.end = p
            } else {
                a.end = shift ? constrained(a.kind, from: a.start, to: p) : p
            }
            drag = .creating(a)
            needsDisplay = true
        case .moving(let last):
            guard let i = state.index(of: selectedID) else { return }
            state.annotations[i].move(by: p.x - last.x, p.y - last.y)
            drag = .moving(last: p)
        case .handle(let h):
            guard let i = state.index(of: selectedID) else { return }
            var a = state.annotations[i]
            let anchor = a.kind.isBoxed ? a.handles[(h + 2) % 4] : (h == 0 ? a.end : a.start)
            a.moveHandle(h, to: shift ? constrained(a.kind, from: anchor, to: p) : p)
            state.annotations[i] = a
        case .cropping(let origin):
            var c = clampToImage(p)
            if shift { c = clampToImage(constrained(.rectangle, from: origin, to: c)) }
            cropRect = CGRect(x: min(origin.x, c.x), y: min(origin.y, c.y),
                              width: abs(c.x - origin.x), height: abs(c.y - origin.y))
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            drag = .none
            stateBeforeDrag = nil
        }
        switch drag {
        case .creating(let a):
            let bigEnough = a.kind.isFreehand ? a.points.count > 1 : hypot(a.end.x - a.start.x, a.end.y - a.start.y) * scale >= 4
            if bigEnough, let before = stateBeforeDrag {
                state.annotations.append(a)
                selectedID = a.id
                registerUndo(from: before, name: tool.title)
            }
            needsDisplay = true
        case .moving, .handle:
            if let before = stateBeforeDrag, !before.sameContent(as: state) {
                registerUndo(from: before, name: "Move")
            }
        case .cropping:
            if let r = cropRect, r.width * scale < 4 || r.height * scale < 4 { cropRect = nil }
        case .none:
            break
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        switch event.keyCode {
        case 51, 117: // delete, forward delete
            deleteSelected()
            return
        case 53: // escape
            if cropRect != nil { cancelCrop() } else { selectedID = nil }
            return
        case 36, 76: // return, enter
            if cropRect != nil { applyCrop(); return }
        case 123, 124, 125, 126: // arrows
            nudge(keyCode: event.keyCode, step: mods.contains(.shift) ? 10 : 1)
            return
        default:
            break
        }
        if mods.isEmpty, let ch = event.charactersIgnoringModifiers?.lowercased() {
            if let t = Tool.allCases.first(where: { $0.key == ch }) {
                onToolRequest?(t)
                return
            }
        }
        super.keyDown(with: event)
    }

    private func nudge(keyCode: UInt16, step: CGFloat) {
        guard let i = state.index(of: selectedID) else { return }
        let before = state
        let d = step / scale
        switch keyCode {
        case 123: state.annotations[i].move(by: -d, 0)
        case 124: state.annotations[i].move(by: d, 0)
        case 125: state.annotations[i].move(by: 0, d)
        default: state.annotations[i].move(by: 0, -d)
        }
        registerUndo(from: before, name: "Move")
    }

    // MARK: - Edit menu

    @objc func copy(_ sender: Any?) {
        ImageFiles.copyToPasteboard(state)
    }

    @objc func delete(_ sender: Any?) {
        deleteSelected()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(delete(_:)) { return selectedID != nil }
        return true
    }

    func deleteSelected() {
        guard let i = state.index(of: selectedID) else { return }
        let before = state
        state.annotations.remove(at: i)
        selectedID = nil
        registerUndo(from: before, name: "Delete")
    }

    // MARK: - Style changes from the toolbar

    func setColor(_ color: NSColor) {
        currentColor = color
        if let tf = textField {
            textColor = color
            tf.textColor = color
        } else if let i = state.index(of: selectedID), state.annotations[i].color != color {
            let before = state
            state.annotations[i].color = color
            registerUndo(from: before, name: "Color")
        }
    }

    func setSize(_ size: Int) {
        currentSize = size
        if textField != nil {
            textSize = size
            textField?.font = TextStyle.font(Annotation.fontSizes[size] * scale)
            layoutTextField()
        } else if let i = state.index(of: selectedID), state.annotations[i].size != size {
            let before = state
            state.annotations[i].size = size
            registerUndo(from: before, name: "Size")
        }
    }

    private func toolChanged(from old: Tool) {
        guard old != tool else { return }
        commitText()
        if old == .crop { cropRect = nil }
        if tool == .crop {
            toolBeforeCrop = old
            selectedID = nil
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    // MARK: - Crop

    func applyCrop() {
        guard let r0 = cropRect else { return }
        let r = r0.intersection(state.bounds)
        let s = state.pixelScale
        let px = CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s).integral
        guard px.width >= 1, px.height >= 1, let image = state.image.cropping(to: px) else { return }

        let before = state
        var next = state
        next.image = image
        next.size = CGSize(width: px.width / s, height: px.height / s)
        for i in next.annotations.indices {
            next.annotations[i].move(by: -px.minX / s, -px.minY / s)
        }
        cropRect = nil
        selectedID = nil
        state = next
        registerUndo(from: before, name: "Crop")
        onToolRequest?(toolBeforeCrop)
    }

    func cancelCrop() {
        cropRect = nil
        onToolRequest?(toolBeforeCrop)
    }

    // MARK: - Undo

    private func registerUndo(from old: DocState, name: String) {
        guard let um = undoManager else { return }
        um.registerUndo(withTarget: self) { view in
            let current = view.state
            view.cancelText()
            view.cropRect = nil
            view.state = old
            if view.state.index(of: view.selectedID) == nil { view.selectedID = nil }
            view.registerUndo(from: current, name: name)
        }
        um.setActionName(name)
    }

    // MARK: - Text editing

    private func beginTextEditing(at p: CGPoint? = nil, existing: Annotation? = nil) {
        textOrigin = existing?.start ?? p ?? .zero
        textColor = existing?.color ?? currentColor
        textSize = existing?.size ?? currentSize
        editingTextID = existing?.id

        let tf = NSTextField(string: existing?.text ?? "")
        tf.isBordered = false
        tf.drawsBackground = true
        tf.backgroundColor = (textColor.isLight ? NSColor.black : NSColor.white).withAlphaComponent(0.55)
        tf.focusRingType = .none
        tf.textColor = textColor
        tf.font = TextStyle.font(Annotation.fontSizes[textSize] * scale)
        tf.usesSingleLineMode = false
        tf.cell?.wraps = false
        tf.cell?.isScrollable = false
        tf.delegate = self
        addSubview(tf)
        textField = tf
        layoutTextField()
        window?.makeFirstResponder(tf)
        if let editor = tf.currentEditor() {
            editor.selectedRange = NSRange(location: (tf.stringValue as NSString).length, length: 0)
        }
        needsDisplay = true
    }

    private func layoutTextField() {
        guard let tf = textField else { return }
        tf.sizeToFit()
        let o = toView(textOrigin)
        tf.frame = CGRect(x: o.x - 2, y: o.y, width: max(tf.frame.width + 16, 60), height: tf.frame.height)
    }

    private func commitText() {
        guard let tf = textField else { return }
        textField = nil
        tf.delegate = nil
        let text = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        tf.removeFromSuperview()

        let before = state
        if let i = state.index(of: editingTextID) {
            if text.isEmpty {
                state.annotations.remove(at: i)
                selectedID = nil
            } else {
                state.annotations[i].text = text
                state.annotations[i].color = textColor
                state.annotations[i].size = textSize
            }
        } else if !text.isEmpty {
            var a = Annotation(kind: .text, start: textOrigin, color: textColor, size: textSize)
            a.text = text
            state.annotations.append(a)
            selectedID = a.id
        }
        editingTextID = nil
        if !before.sameContent(as: state) { registerUndo(from: before, name: "Text") }
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    private func cancelText() {
        guard let tf = textField else { return }
        textField = nil
        tf.delegate = nil
        tf.removeFromSuperview()
        editingTextID = nil
        needsDisplay = true
        window?.makeFirstResponder(self)
    }

    func controlTextDidChange(_ obj: Notification) {
        layoutTextField()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitText()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            cancelText()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            commitText()
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            textView.insertText("\n", replacementRange: textView.selectedRange())
            layoutTextField()
            return true
        default:
            return false
        }
    }
}
