import AppKit

enum Tool: Int, CaseIterable {
    case select, arrow, text, rectangle, roundedRect, ellipse, line, pen, highlighter, pixelate, crop

    var title: String {
        switch self {
        case .select: "Select"
        case .arrow: "Arrow"
        case .text: "Text"
        case .rectangle: "Rectangle"
        case .roundedRect: "Rounded Rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .pixelate: "Pixelate"
        case .crop: "Crop"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        case .rectangle: "rectangle"
        case .roundedRect: "app"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .pen: "scribble"
        case .highlighter: "highlighter"
        case .pixelate: "checkerboard.rectangle"
        case .crop: "crop"
        }
    }

    /// Single-key shortcut used while the canvas has focus.
    var key: String {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .text: "t"
        case .rectangle: "r"
        case .roundedRect: "u"
        case .ellipse: "o"
        case .line: "l"
        case .pen: "p"
        case .highlighter: "h"
        case .pixelate: "x"
        case .crop: "c"
        }
    }

    var kind: ShapeKind? {
        switch self {
        case .select, .crop: nil
        case .arrow: .arrow
        case .text: .text
        case .rectangle: .rectangle
        case .roundedRect: .roundedRect
        case .ellipse: .ellipse
        case .line: .line
        case .pen: .pen
        case .highlighter: .highlighter
        case .pixelate: .pixelate
        }
    }
}

enum ShapeKind {
    case arrow, line, rectangle, roundedRect, ellipse, pen, highlighter, text, pixelate

    var isFreehand: Bool { self == .pen || self == .highlighter }
    var isBoxed: Bool { [.rectangle, .roundedRect, .ellipse, .pixelate].contains(self) }
}

enum Palette {
    static let colors: [NSColor] = [
        NSColor(srgbRed: 0.91, green: 0.20, blue: 0.33, alpha: 1),
        NSColor(srgbRed: 0.98, green: 0.55, blue: 0.13, alpha: 1),
        NSColor(srgbRed: 1.00, green: 0.85, blue: 0.15, alpha: 1),
        NSColor(srgbRed: 0.30, green: 0.75, blue: 0.33, alpha: 1),
        NSColor(srgbRed: 0.16, green: 0.50, blue: 0.95, alpha: 1),
        NSColor(srgbRed: 0.58, green: 0.33, blue: 0.86, alpha: 1),
        NSColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1),
        NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1),
    ]
    static let colorNames = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Black", "White"]
    static let sizeNames = ["S", "M", "L", "XL"]
    static let sizeTitles = ["Small", "Medium", "Large", "Extra Large"]
}

extension NSColor {
    var isLight: Bool {
        guard let c = usingColorSpace(.sRGB) else { return false }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.75
    }
}

struct Annotation: Equatable {
    let id: UUID
    var kind: ShapeKind
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint]
    var color: NSColor
    var size: Int
    var text = ""

    static let lineWidths: [CGFloat] = [3, 5, 8, 13]
    static let highlighterWidths: [CGFloat] = [12, 20, 30, 44]
    static let fontSizes: [CGFloat] = [16, 24, 36, 54]
    static let pixelBlocks: [CGFloat] = [6, 10, 16, 24]

    init(kind: ShapeKind, start: CGPoint, color: NSColor, size: Int) {
        id = UUID()
        self.kind = kind
        self.start = start
        end = start
        points = [start]
        self.color = color
        self.size = size
    }

    var lineWidth: CGFloat { kind == .highlighter ? Self.highlighterWidths[size] : Self.lineWidths[size] }
    var fontSize: CGFloat { Self.fontSizes[size] }
    var pixelBlock: CGFloat { Self.pixelBlocks[size] }

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var bounds: CGRect {
        switch kind {
        case .text:
            return CGRect(origin: start, size: TextStyle.size(of: text, fontSize: fontSize))
        case .pen, .highlighter:
            let xs = points.map(\.x), ys = points.map(\.y)
            let r = CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0,
                           width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
            return r.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        case .arrow:
            return rect.insetBy(dx: -lineWidth * 3, dy: -lineWidth * 3)
        default:
            return rect.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        }
    }

    /// `interior` lets clicks inside a box select it; otherwise only its outline counts,
    /// so drawing a new arrow that starts inside a rectangle doesn't grab the rectangle.
    func hit(_ p: CGPoint, tolerance tol: CGFloat, interior: Bool) -> Bool {
        let reach = lineWidth / 2 + tol
        switch kind {
        case .arrow:
            return distance(p, toSegment: start, end) <= lineWidth * 1.5 + tol
        case .line:
            return distance(p, toSegment: start, end) <= reach
        case .pen, .highlighter:
            if points.count == 1 { return hypot(p.x - start.x, p.y - start.y) <= reach }
            return zip(points, points.dropFirst()).contains { distance(p, toSegment: $0, $1) <= reach }
        case .text:
            return bounds.insetBy(dx: -tol, dy: -tol).contains(p)
        case .rectangle, .roundedRect, .pixelate:
            let edge = kind == .pixelate ? tol : reach
            let outer = rect.insetBy(dx: -edge, dy: -edge)
            if interior { return outer.contains(p) }
            let inner = rect.insetBy(dx: edge, dy: edge)
            return outer.contains(p) && (inner.isNull || !inner.contains(p))
        case .ellipse:
            let r = rect
            let rx = max(r.width / 2, 0.5), ry = max(r.height / 2, 0.5)
            let nx = (p.x - r.midX) / rx, ny = (p.y - r.midY) / ry
            let d = sqrt(nx * nx + ny * ny)
            if interior { return d <= 1 + reach / min(rx, ry) }
            return abs(d - 1) * min(rx, ry) <= reach
        }
    }

    mutating func move(by dx: CGFloat, _ dy: CGFloat) {
        start.x += dx; start.y += dy
        end.x += dx; end.y += dy
        points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    var handles: [CGPoint] {
        switch kind {
        case .arrow, .line:
            return [start, end]
        case .rectangle, .roundedRect, .ellipse, .pixelate:
            let r = rect
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                    CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        case .pen, .highlighter, .text:
            return []
        }
    }

    mutating func moveHandle(_ index: Int, to p: CGPoint) {
        if kind.isBoxed {
            start = handles[(index + 2) % 4]
            end = p
        } else if index == 0 {
            start = p
        } else {
            end = p
        }
    }
}

func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let len2 = dx * dx + dy * dy
    guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

/// Snaps lines to 45° steps and boxes to squares (shift-drag).
func constrained(_ kind: ShapeKind, from s: CGPoint, to p: CGPoint) -> CGPoint {
    let dx = p.x - s.x, dy = p.y - s.y
    switch kind {
    case .arrow, .line:
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        let len = hypot(dx, dy)
        return CGPoint(x: s.x + cos(angle) * len, y: s.y + sin(angle) * len)
    default:
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: s.x + (dx < 0 ? -side : side), y: s.y + (dy < 0 ? -side : side))
    }
}

enum TextStyle {
    static func font(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .bold) }

    static func size(of text: String, fontSize: CGFloat) -> CGSize {
        let s = (text.isEmpty ? " " : text) as NSString
        let r = s.boundingRect(with: CGSize(width: 100_000, height: 100_000),
                               options: [.usesLineFragmentOrigin],
                               attributes: [.font: font(fontSize)])
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }
}

/// The whole editable document: base bitmap plus vector annotations in image points.
struct DocState {
    var image: CGImage
    var size: CGSize
    var annotations: [Annotation] = []

    var pixelScale: CGFloat { CGFloat(image.width) / size.width }
    var bounds: CGRect { CGRect(origin: .zero, size: size) }

    func index(of id: UUID?) -> Int? {
        guard let id else { return nil }
        return annotations.firstIndex { $0.id == id }
    }

    func sameContent(as other: DocState) -> Bool {
        image === other.image && size == other.size && annotations == other.annotations
    }
}
