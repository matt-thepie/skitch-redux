import AppKit

/// Colours and drawing helpers for the Skitch 2.x look: light grey chrome, dark selected tools.
enum SkitchLook {
    static let chrome = NSColor(srgbRed: 0.925, green: 0.925, blue: 0.918, alpha: 1)
    static let edge = NSColor(white: 0.20, alpha: 1)
    static let hairline = NSColor(white: 0.74, alpha: 1)
    static let icon = NSColor(white: 0.40, alpha: 1)
    static let text = NSColor(white: 0.22, alpha: 1)
    static let selected = NSColor(srgbRed: 0.37, green: 0.37, blue: 0.355, alpha: 1)

    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .semibold, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(.init(paletteColors: [color]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    /// Draws an image centred on `point` in a (usually flipped) view.
    static func draw(_ image: NSImage, centeredAt point: CGPoint) {
        let s = image.size
        image.draw(in: CGRect(x: round(point.x - s.width / 2), y: round(point.y - s.height / 2), width: s.width, height: s.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    static func swatch(_ color: NSColor, diameter: CGFloat = 14) -> NSImage {
        NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { r in
            let dot = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5))
            color.setFill()
            dot.fill()
            NSColor.black.withAlphaComponent(0.3).setStroke()
            dot.stroke()
            return true
        }
    }

    static func lineWeight(_ size: Int) -> NSImage {
        NSImage(size: NSSize(width: 28, height: 14), flipped: false) { r in
            let path = NSBezierPath()
            path.move(to: CGPoint(x: 2, y: r.midY))
            path.line(to: CGPoint(x: r.maxX - 2, y: r.midY))
            path.lineWidth = sizeStroke(size)
            path.lineCapStyle = .round
            NSColor.labelColor.setStroke()
            path.stroke()
            return true
        }
    }

    static func sizeStroke(_ size: Int) -> CGFloat { [1.5, 2.5, 4, 6][min(max(size, 0), 3)] }
}

/// Menu item that runs a closure, so menus can be built inline.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, image: NSImage? = nil, checked: Bool = false, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        self.image = image
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { handler() }
}

// MARK: - Tool rail

final class RailButton: NSView {
    enum Content {
        case symbol(String)
        case letter
        case color(NSColor)
        case size(Int)
    }

    var content: Content { didSet { needsDisplay = true } }
    var isSelected = false { didSet { needsDisplay = true } }
    /// Shows the corner triangle; press-and-hold (or click the triangle) opens the menu.
    var hasMenu = false
    /// Colour and size open their menu on a plain click.
    var menuOnClick = false
    var onClick: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?

    init(_ content: Content, tip: String) {
        self.content = content
        super.init(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
        toolTip = tip
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 40).isActive = true
        heightAnchor.constraint(equalToConstant: 40).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            SkitchLook.selected.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        let tint = isSelected ? NSColor.white : SkitchLook.icon
        let c = CGPoint(x: bounds.midX, y: bounds.midY)

        switch content {
        case .symbol(let name):
            if let img = SkitchLook.symbol(name, size: 17, color: tint) { SkitchLook.draw(img, centeredAt: c) }
        case .letter:
            let base = NSFont.systemFont(ofSize: 26, weight: .heavy)
            let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 26) } ?? base
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tint]
            let s = ("a" as NSString).size(withAttributes: attrs)
            ("a" as NSString).draw(at: CGPoint(x: c.x - s.width / 2, y: c.y - s.height / 2 - 2), withAttributes: attrs)
        case .color(let color):
            let ring = NSBezierPath(ovalIn: CGRect(x: c.x - 11, y: c.y - 11, width: 22, height: 22))
            ring.lineWidth = 1.5
            tint.setStroke()
            ring.stroke()
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16)).fill()
        case .size(let size):
            let ring = NSBezierPath(ovalIn: CGRect(x: c.x - 11, y: c.y - 11, width: 22, height: 22))
            ring.lineWidth = 1.5
            tint.setStroke()
            ring.stroke()
            let slash = NSBezierPath()
            slash.move(to: CGPoint(x: c.x - 5.5, y: c.y + 5.5))
            slash.line(to: CGPoint(x: c.x + 5.5, y: c.y - 5.5))
            slash.lineWidth = SkitchLook.sizeStroke(size)
            slash.lineCapStyle = .round
            slash.stroke()
        }

        if hasMenu || menuOnClick {
            let t = NSBezierPath()
            t.move(to: CGPoint(x: bounds.maxX - 3, y: bounds.maxY - 3))
            t.line(to: CGPoint(x: bounds.maxX - 3, y: bounds.maxY - 8))
            t.line(to: CGPoint(x: bounds.maxX - 8, y: bounds.maxY - 3))
            t.close()
            tint.setFill()
            t.fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let inCorner = p.x > bounds.maxX - 14 && p.y > bounds.maxY - 14
        if menuOnClick || (hasMenu && inCorner) {
            showMenu()
            return
        }
        guard hasMenu else {
            onClick?()
            return
        }
        // Skitch-style: a quick click selects, holding opens the variants menu.
        let up = window?.nextEvent(matching: .leftMouseUp, until: Date(timeIntervalSinceNow: 0.35),
                                   inMode: .eventTracking, dequeue: true)
        if up == nil {
            onClick?()
            showMenu()
        } else {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if hasMenu || menuOnClick { showMenu() } else { super.rightMouseDown(with: event) }
    }

    private func showMenu() {
        guard let menu = menuProvider?() else { return }
        menu.popUp(positioning: nil, at: CGPoint(x: bounds.maxX + 4, y: 0), in: self)
    }
}

/// Skitch's vertical tool palette. Tools with variants (shapes, pens) share one button.
final class ToolRail: NSView {
    private static let groups: [[Tool]] = [
        [.arrow, .line],
        [.text],
        [.rectangle, .roundedRect, .ellipse],
        [.pen, .highlighter],
        [.pixelate],
        [.crop],
    ]

    var onSelectTool: ((Tool) -> Void)?
    let colorButton = RailButton(.color(Palette.colors[0]), tip: "Colour")
    let sizeButton = RailButton(.size(1), tip: "Line width / text size")

    private var current: [Tool] = ToolRail.groups.map { $0[0] }
    private var buttons: [RailButton] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (i, group) in Self.groups.enumerated() {
            let b = RailButton(Self.content(for: group[0]), tip: Self.tip(for: group))
            b.hasMenu = group.count > 1
            b.onClick = { [weak self] in
                guard let self else { return }
                self.onSelectTool?(self.current[i])
            }
            b.menuProvider = { [weak self] in self?.variantMenu(group: i) }
            buttons.append(b)
            stack.addArrangedSubview(b)
        }

        let rule = NSBox()
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.widthAnchor.constraint(equalToConstant: 36).isActive = true
        stack.addArrangedSubview(rule)
        stack.setCustomSpacing(12, after: buttons.last!)
        stack.setCustomSpacing(12, after: rule)

        colorButton.menuOnClick = true
        sizeButton.menuOnClick = true
        stack.addArrangedSubview(colorButton)
        stack.addArrangedSubview(sizeButton)

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor, constant: -0.5),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 30),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
            widthAnchor.constraint(equalToConstant: 56),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        SkitchLook.chrome.setFill()
        bounds.fill()
        SkitchLook.edge.setFill()
        CGRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    /// Highlights the group containing `tool` and makes it that group's shown variant.
    func select(_ tool: Tool) {
        for (i, group) in Self.groups.enumerated() {
            let hit = group.contains(tool)
            if hit {
                current[i] = tool
                buttons[i].content = Self.content(for: tool)
                buttons[i].toolTip = Self.tip(for: group, showing: tool)
            }
            buttons[i].isSelected = hit
        }
    }

    private func variantMenu(group i: Int) -> NSMenu? {
        let group = Self.groups[i]
        guard group.count > 1 else { return nil }
        let menu = NSMenu()
        for t in group {
            let img = SkitchLook.symbol(Self.symbol(for: t), size: 14, weight: .medium, color: .labelColor)
            menu.addItem(ClosureMenuItem("\(t.title)  (\(t.key.uppercased()))", image: img, checked: t == current[i]) { [weak self] in
                self?.onSelectTool?(t)
            })
        }
        return menu
    }

    private static func tip(for group: [Tool], showing tool: Tool? = nil) -> String {
        let t = tool ?? group[0]
        let base = "\(t.title) (\(t.key.uppercased()))"
        return group.count > 1 ? base + " — hold for more" : base
    }

    private static func content(for tool: Tool) -> RailButton.Content {
        tool == .text ? .letter : .symbol(symbol(for: tool))
    }

    /// Icons chosen to echo Skitch's palette rather than the generic `Tool.symbol`.
    private static func symbol(for tool: Tool) -> String {
        switch tool {
        case .arrow: "arrow.down.left"
        case .pen: "pencil"
        case .pixelate: "eye.slash"
        case .rectangle: "rectangle"
        default: tool.symbol
        }
    }
}

// MARK: - Screen Snap split button

final class SnapButton: NSView {
    var onSnap: (() -> Void)?
    var onMenu: ((NSView) -> Void)?
    private var pressed: Int?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 186, height: 24) }

    private var splitX: CGFloat { bounds.maxX - 26 }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        NSGradient(starting: NSColor(white: 0.93, alpha: 1), ending: NSColor(white: 0.84, alpha: 1))?.draw(in: shape, angle: 90)
        if let pressed {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            NSColor.black.withAlphaComponent(0.1).setFill()
            (pressed == 0 ? CGRect(x: 0, y: 0, width: splitX, height: bounds.height)
                          : CGRect(x: splitX, y: 0, width: bounds.maxX - splitX, height: bounds.height)).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSColor(white: 0.6, alpha: 1).setStroke()
        shape.stroke()
        NSColor(white: 0.68, alpha: 1).setFill()
        CGRect(x: splitX, y: 3, width: 1, height: bounds.height - 6).fill()

        let ink = NSColor(white: 0.38, alpha: 1)
        if let img = SkitchLook.symbol("rectangle.dashed", size: 13, weight: .regular, color: ink) {
            SkitchLook.draw(img, centeredAt: CGPoint(x: 20, y: bounds.midY))
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: ink]
        let label = "Screen Snap" as NSString
        let size = label.size(withAttributes: attrs)
        label.draw(at: CGPoint(x: 36, y: (bounds.height - size.height) / 2), withAttributes: attrs)

        let mid = CGPoint(x: (splitX + bounds.maxX) / 2, y: bounds.midY)
        let tri = NSBezierPath()
        tri.move(to: CGPoint(x: mid.x - 3.5, y: mid.y - 2))
        tri.line(to: CGPoint(x: mid.x + 3.5, y: mid.y - 2))
        tri.line(to: CGPoint(x: mid.x, y: mid.y + 2.5))
        tri.close()
        ink.setFill()
        tri.fill()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        pressed = p.x < splitX ? 0 : 1
        needsDisplay = true
        if pressed == 1 {
            pressed = nil
            needsDisplay = true
            onMenu?(self)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed == 0 else { return }
        pressed = nil
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onSnap?() }
    }
}

/// One row in the dark Screen Snap menu.
private final class SnapRow: NSView {
    private let symbol: String
    private let title: String
    private let action: () -> Void
    private var hovering = false { didSet { needsDisplay = true } }

    init(_ title: String, symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        widthAnchor.constraint(equalToConstant: 250).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseUp(with event: NSEvent) { action() }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            NSColor.white.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        if let img = SkitchLook.symbol(symbol, size: 15, weight: .medium, color: .white) {
            SkitchLook.draw(img, centeredAt: CGPoint(x: 22, y: bounds.midY))
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.white]
        let s = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: CGPoint(x: 42, y: (bounds.height - s.height) / 2), withAttributes: attrs)
    }
}

/// The dark popover under the Screen Snap button.
enum SnapMenu {
    static func show(from anchor: NSView) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)

        let entries: [(String, String, Selector)] = [
            ("Fullscreen", "viewfinder", #selector(AppDelegate.captureFullscreen(_:))),
            ("Screen Snap…", "rectangle.dashed", #selector(AppDelegate.captureRegion(_:))),
            ("Window Snap…", "macwindow", #selector(AppDelegate.captureWindow(_:))),
            ("Timed Screen Snap…", "timer", #selector(AppDelegate.captureTimed(_:))),
            ("Open an Image…", "folder.fill", #selector(AppDelegate.openDocument(_:))),
            ("From Clipboard", "doc.on.clipboard.fill", #selector(AppDelegate.newFromClipboard(_:))),
            ("Blank", "doc.fill", #selector(AppDelegate.newBlank(_:))),
        ]
        let stack = NSStackView(views: entries.map { title, symbol, sel in
            SnapRow(title, symbol: symbol) { [weak popover] in
                popover?.performClose(nil)
                NSApp.sendAction(sel, to: nil, from: nil)
            }
        })
        stack.orientation = .vertical
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)

        let vc = NSViewController()
        vc.view = stack
        popover.contentViewController = vc
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }
}

// MARK: - Bars

/// Plain chrome-coloured strip with a hairline on one edge.
final class ChromeBar: NSView {
    enum Edge { case top, bottom }
    private let edge: Edge

    init(hairline edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        SkitchLook.chrome.setFill()
        bounds.fill()
        SkitchLook.hairline.setFill()
        CGRect(x: 0, y: edge == .top ? 0 : bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
}

/// Borderless grey icon button for the toolbar (share, trash).
func chromeIconButton(_ symbol: String, tip: String, target: AnyObject, action: Selector) -> NSButton {
    let b = NSButton(image: SkitchLook.symbol(symbol, size: 15, weight: .regular, color: SkitchLook.icon)!, target: target, action: action)
    b.isBordered = false
    b.toolTip = tip
    b.refusesFirstResponder = true
    return b
}
