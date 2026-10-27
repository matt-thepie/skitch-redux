import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ImageFiles {
    static func load(url: URL) -> DocState? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return load(source: src)
    }

    static func load(data: Data) -> DocState? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return load(source: src)
    }

    static func load(pasteboard pb: NSPasteboard) -> DocState? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingContentsConformToTypes: [UTType.image.identifier]]
        if let url = (pb.readObjects(forClasses: [NSURL.self], options: options) as? [URL])?.first,
           let state = load(url: url) {
            return state
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier)] {
            if let data = pb.data(forType: type), let state = load(data: data) { return state }
        }
        if let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation {
            return load(data: tiff)
        }
        return nil
    }

    private static func load(source src: CGImageSource) -> DocState? {
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1

        let image: CGImage?
        if orientation != 1 {
            // Bake EXIF rotation into the pixels so annotations line up with what the user sees.
            let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
            let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(w, h),
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        guard let image else { return nil }

        // Retina screenshots are 144 dpi; work in points so stroke sizes feel the same everywhere.
        let dpi = (props[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
        let scale = max(1, dpi / 72)
        let size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        return DocState(image: image, size: size)
    }

    /// Renders base image + annotations at full pixel resolution.
    static func flatten(_ state: DocState) -> CGImage? {
        let w = state.image.width, h = state.image.height
        var space = CGColorSpace(name: CGColorSpace.sRGB)!
        if let cs = state.image.colorSpace, cs.model == .rgb, cs.supportsOutput { space = cs }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }

        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.scaleBy(x: state.pixelScale, y: state.pixelScale)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        Renderer.draw(state, in: ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    static func encode(_ state: DocState, as type: UTType) -> Data? {
        guard let image = flatten(state) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * state.pixelScale
        var props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        if type == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func copyToPasteboard(_ state: DocState) {
        guard let png = encode(state, as: .png), let image = flatten(state) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.png, .tiff], owner: nil)
        pb.setData(png, forType: .png)
        if let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation {
            pb.setData(tiff, forType: .tiff)
        }
    }

    static func defaultName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Skitch Redux \(f.string(from: Date()))"
    }
}
