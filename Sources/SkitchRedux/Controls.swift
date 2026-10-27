import AppKit
import UniformTypeIdentifiers

/// Writes the chosen format to a file when dropped in Finder, and offers raw PNG data to apps that take images.
final class ImagePromiseProvider: NSFilePromiseProvider {
    var png = Data()
    var file = Data()

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.png]
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == .png ? [] : super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == .png ? png : super.pasteboardPropertyList(forType: type)
    }
}

/// Skitch's drag tab in the bottom bar: drag the annotated image straight into Finder, Mail, Slack, etc.
final class DragOutView: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    private let stateProvider: () -> DocState
    private let formatProvider: () -> UTType
    private let nameProvider: () -> String
    private var dragStarted = false

    init(state: @escaping () -> DocState, format: @escaping () -> UTType, name: @escaping () -> String) {
        stateProvider = state
        formatProvider = format
        nameProvider = name
        super.init(frame: .zero)
        toolTip = "Drag the annotated image to another app or to Finder"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 160, height: 30) }

    override func draw(_ dirtyRect: NSRect) {
        // A tab hanging from the bar's top edge: wide at the top, sloping in to a rounded bottom.
        let b = bounds
        let inset: CGFloat = 16, r: CGFloat = 5
        let tab = NSBezierPath()
        tab.move(to: CGPoint(x: b.minX, y: b.minY))
        tab.line(to: CGPoint(x: b.minX + inset - r * 0.4, y: b.maxY - r))
        tab.curve(to: CGPoint(x: b.minX + inset + r, y: b.maxY),
                  controlPoint1: CGPoint(x: b.minX + inset, y: b.maxY), controlPoint2: CGPoint(x: b.minX + inset, y: b.maxY))
        tab.line(to: CGPoint(x: b.maxX - inset - r, y: b.maxY))
        tab.curve(to: CGPoint(x: b.maxX - inset + r * 0.4, y: b.maxY - r),
                  controlPoint1: CGPoint(x: b.maxX - inset, y: b.maxY), controlPoint2: CGPoint(x: b.maxX - inset, y: b.maxY))
        tab.line(to: CGPoint(x: b.maxX, y: b.minY))
        NSColor(white: 0.975, alpha: 1).setFill()
        tab.fill()
        SkitchLook.hairline.setStroke()
        tab.lineWidth = 1
        tab.stroke()

        // Grip lines either side of the file icon.
        let mid = CGPoint(x: b.midX, y: b.midY + 1)
        NSColor(white: 0.62, alpha: 1).setFill()
        for i in 0..<3 {
            let y = mid.y - 4 + CGFloat(i) * 4
            let len: CGFloat = i == 1 ? 26 : 20
            CGRect(x: mid.x - 16 - len, y: y, width: len, height: 1).fill()
            CGRect(x: mid.x + 16, y: y, width: len, height: 1).fill()
        }

        // Document icon with a folded corner and a red format badge.
        let doc = CGRect(x: mid.x - 8, y: mid.y - 10, width: 16, height: 20)
        let fold: CGFloat = 5
        let page = NSBezierPath()
        page.move(to: CGPoint(x: doc.minX, y: doc.minY))
        page.line(to: CGPoint(x: doc.maxX - fold, y: doc.minY))
        page.line(to: CGPoint(x: doc.maxX, y: doc.minY + fold))
        page.line(to: CGPoint(x: doc.maxX, y: doc.maxY))
        page.line(to: CGPoint(x: doc.minX, y: doc.maxY))
        page.close()
        NSColor.white.setFill()
        page.fill()
        NSColor(white: 0.55, alpha: 1).setStroke()
        page.lineWidth = 0.75
        page.stroke()

        let badge = CGRect(x: doc.minX - 2, y: doc.midY - 1, width: doc.width + 4, height: 7)
        NSColor(srgbRed: 0.88, green: 0.18, blue: 0.30, alpha: 1).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 1.5, yRadius: 1.5).fill()
        let label = (formatProvider() == .jpeg ? "JPG" : "PNG") as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 5.5, weight: .black), .foregroundColor: NSColor.white]
        let s = label.size(withAttributes: attrs)
        label.draw(at: CGPoint(x: badge.midX - s.width / 2, y: badge.midY - s.height / 2), withAttributes: attrs)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted else { return }
        dragStarted = true
        let state = stateProvider()
        let format = formatProvider()
        guard let png = ImageFiles.encode(state, as: .png),
              let file = format == .png ? png : ImageFiles.encode(state, as: format) else { return }

        let provider = ImagePromiseProvider(fileType: format.identifier, delegate: self)
        provider.png = png
        provider.file = file
        let item = NSDraggingItem(pasteboardWriter: provider)

        let thumbScale = min(1, 200 / max(state.size.width, state.size.height))
        let thumbSize = CGSize(width: state.size.width * thumbScale, height: state.size.height * thumbScale)
        let p = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(CGRect(x: p.x - thumbSize.width / 2, y: p.y - thumbSize.height / 2,
                                     width: thumbSize.width, height: thumbSize.height),
                              contents: NSImage(data: png))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        nameProvider() + (fileType == UTType.jpeg.identifier ? ".jpg" : ".png")
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        do {
            try ((filePromiseProvider as? ImagePromiseProvider)?.file ?? Data()).write(to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }
}
