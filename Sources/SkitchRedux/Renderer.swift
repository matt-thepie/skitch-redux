import AppKit

/// Draws a document into a flipped (top-left origin) context whose user space is image points.
/// Used both for the on-screen canvas and for export, so what you see is what you save.
enum Renderer {
    static func draw(_ state: DocState, hiding hiddenID: UUID? = nil, in ctx: CGContext) {
        drawBase(state, in: ctx)
        // Pixelation reads the base image, so it goes underneath everything else.
        let ordered = state.annotations.filter { $0.kind == .pixelate } + state.annotations.filter { $0.kind != .pixelate }
        for a in ordered where a.id != hiddenID {
            draw(a, on: state, in: ctx)
        }
    }

    static func drawBase(_ state: DocState, in ctx: CGContext) {
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: state.size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(state.image, in: state.bounds)
        ctx.restoreGState()
    }

    static func draw(_ a: Annotation, on state: DocState, in ctx: CGContext) {
        // Shadows ignore the CTM, so scale them to keep the look consistent at any zoom.
        let device = abs(ctx.userSpaceToDeviceSpaceTransform.a)
        ctx.saveGState()
        defer { ctx.restoreGState() }

        func shadow() {
            ctx.setShadow(offset: CGSize(width: 0, height: -1.5 * device), blur: 4 * device,
                          color: NSColor.black.withAlphaComponent(0.45).cgColor)
        }

        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(a.lineWidth)
        ctx.setStrokeColor(a.color.cgColor)

        switch a.kind {
        case .arrow:
            guard let path = arrowPath(a) else { return }
            shadow()
            ctx.addPath(path)
            ctx.setFillColor(a.color.cgColor)
            ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(max(1, a.lineWidth * 0.22))
            ctx.strokePath()

        case .line:
            shadow()
            ctx.move(to: a.start)
            ctx.addLine(to: a.end)
            ctx.strokePath()

        case .rectangle:
            shadow()
            ctx.stroke(a.rect)

        case .roundedRect:
            let r = a.rect
            let radius = min(a.lineWidth * 2 + 8, min(r.width, r.height) / 2)
            shadow()
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.strokePath()

        case .ellipse:
            shadow()
            ctx.strokeEllipse(in: a.rect)

        case .pen:
            shadow()
            ctx.addPath(smoothPath(a.points))
            ctx.strokePath()

        case .highlighter:
            ctx.setBlendMode(.multiply)
            ctx.setStrokeColor(a.color.withAlphaComponent(0.45).cgColor)
            ctx.setLineCap(.square)
            ctx.addPath(smoothPath(a.points))
            ctx.strokePath()

        case .text:
            drawText(a, shadow: shadow, ctx: ctx)

        case .pixelate:
            drawPixelated(a, on: state, in: ctx)
        }
    }

    // MARK: - Shapes

    /// Skitch's signature arrow: a tapered shaft that swells into a wide barbed head.
    static func arrowPath(_ a: Annotation) -> CGPath? {
        let dx = a.end.x - a.start.x, dy = a.end.y - a.start.y
        let len = hypot(dx, dy)
        guard len > 1 else { return nil }
        let ux = dx / len, uy = dy / len
        let nx = -uy, ny = ux
        let w = a.lineWidth

        let head = min(max(w * 4.5, 16), len * 0.8)
        let headHalf = head * 0.55
        let neckHalf = min(w * 0.75, headHalf * 0.6)
        let tailHalf = w * 0.2

        func pt(_ base: CGPoint, along: CGFloat, across: CGFloat) -> CGPoint {
            CGPoint(x: base.x + ux * along + nx * across, y: base.y + uy * along + ny * across)
        }

        let path = CGMutablePath()
        path.move(to: pt(a.start, along: 0, across: tailHalf))
        path.addLine(to: pt(a.end, along: -head * 0.78, across: neckHalf))
        path.addLine(to: pt(a.end, along: -head, across: headHalf))
        path.addLine(to: a.end)
        path.addLine(to: pt(a.end, along: -head, across: -headHalf))
        path.addLine(to: pt(a.end, along: -head * 0.78, across: -neckHalf))
        path.addLine(to: pt(a.start, along: 0, across: -tailHalf))
        path.closeSubpath()
        return path
    }

    static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 {
            path.addLine(to: first)
            return path
        }
        for i in 1..<points.count {
            let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
            path.addQuadCurve(to: mid, control: points[i - 1])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    static func drawText(_ a: Annotation, shadow: () -> Void, ctx: CGContext) {
        guard !a.text.isEmpty else { return }
        let font = TextStyle.font(a.fontSize)
        let outline: NSColor = a.color.isLight ? .black : .white
        let rect = CGRect(origin: a.start, size: CGSize(width: 100_000, height: 100_000))

        let stroked = NSAttributedString(string: a.text, attributes: [
            .font: font, .strokeColor: outline, .strokeWidth: 18,
        ])
        let filled = NSAttributedString(string: a.text, attributes: [
            .font: font, .foregroundColor: a.color,
        ])

        shadow()
        stroked.draw(with: rect, options: [.usesLineFragmentOrigin])
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        filled.draw(with: rect, options: [.usesLineFragmentOrigin])
    }

    static func drawPixelated(_ a: Annotation, on state: DocState, in ctx: CGContext) {
        let r = a.rect.intersection(state.bounds)
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return }
        let s = state.pixelScale
        let px = CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s).integral
        guard let crop = state.image.cropping(to: px) else { return }

        let cols = max(1, Int((r.width / a.pixelBlock).rounded()))
        let rows = max(1, Int((r.height / a.pixelBlock).rounded()))
        guard let small = CGContext(data: nil, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        small.interpolationQuality = .high
        small.draw(crop, in: CGRect(x: 0, y: 0, width: cols, height: rows))
        guard let tiny = small.makeImage() else { return }

        ctx.interpolationQuality = .none
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(tiny, in: CGRect(origin: .zero, size: r.size))
    }
}
