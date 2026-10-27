import AppKit

/// Proton's menu bar icons, sized for the menu bar.
enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 18)
    static let connected = sized(resource("connected"))
    static let disconnected = sized(resource("disconnected"))

    /// Proton's icon with its badge replaced by three dots, one of them highlighted.
    static let connecting: [NSImage] = (0..<3).map { highlighted in
        let image = NSImage(size: size, flipped: false) { rect in
            resource("disconnected").draw(in: rect)
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            // The badge is a circle in the icon's top right corner (in 36pt units: centre 25.2, 25.6; radius 9.8).
            let scale = rect.width / 36
            let center = CGPoint(x: 25.2 * scale, y: 25.6 * scale)
            let radius = 9.8 * scale
            context.setFillColor(NSColor.black.cgColor)
            context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.setBlendMode(.destinationOut)
            for dot in 0..<3 {
                let r = (dot == highlighted ? 2.1 : 1.3) * scale
                let x = center.x + CGFloat(dot - 1) * 5.4 * scale
                context.fillEllipse(in: CGRect(x: x - r, y: center.y - r, width: r * 2, height: r * 2))
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Proton's connected icon with its triangle filled with the country's flag. Not a template
    /// image, for the flag's colors, so the checkmark badge is drawn in the menu bar's text color.
    @MainActor static func flagged(_ code: String) -> NSImage {
        if let cached = flags[code] { return cached }
        let flagImage = trimmedFlag(code)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            let scale = rect.width / 36
            let badge = CGRect(x: (25.6 - 10.8) * scale, y: (25.8 - 10.8) * scale, width: 21.6 * scale, height: 21.6 * scale)

            context.saveGState()
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            if let solid = solidTriangle { context.draw(solid, in: rect) }
            // The flag scaled to cover the triangle (in the icon's left 30x32), cropped at its sides
            // rather than stretched.
            let box = NSRect(x: 0, y: 0, width: 30 * scale, height: 32 * scale)
            let fill = max(box.width / flagImage.size.width, box.height / flagImage.size.height)
            let size = NSSize(width: flagImage.size.width * fill, height: flagImage.size.height * fill)
            flagImage.draw(in: NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height),
                           from: .zero, operation: .sourceIn, fraction: 1)
            context.endTransparencyLayer()
            context.restoreGState()

            // The checkmark badge, in white or black like the menu bar's template icons.
            context.saveGState()
            context.addEllipse(in: badge)
            context.clip()
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            resource("connected").draw(in: rect)
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            (dark ? NSColor.white : NSColor.black).setFill()
            rect.fill(using: .sourceAtop)
            context.endTransparencyLayer()
            context.restoreGState()
            return true
        }
        flags[code] = image
        return image
    }

    /// Proton's triangle as one solid shape, without the badge or the line inside it, so the flag
    /// fills all of it: the convex hull of the triangle's pixels, with the gap around the badge
    /// (radius 12.1; the badge itself is 10.3) cut out again.
    static let solidTriangle = makeSolidTriangle(from: resource("connected"))

    static func makeSolidTriangle(from icon: NSImage) -> CGImage? {
        let n = 144, scale = Double(n) / 36
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: n, height: n))
        NSGraphicsContext.restoreGraphicsState()

        let center = CGPoint(x: 25.6 * scale, y: 25.8 * scale), gap = 12.1 * scale
        var points: [CGPoint] = []
        for y in 0..<n {
            for x in 0..<n where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                let point = CGPoint(x: Double(x) + 0.5, y: Double(n - y) - 0.5)
                if hypot(point.x - center.x, point.y - center.y) > gap { points.append(point) }
            }
        }
        let hull = convexHull(points)
        guard hull.count > 2 else { return nil }
        let context = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.addLines(between: hull)
        context.closePath()
        context.fillPath()
        context.setBlendMode(.clear)
        context.fillEllipse(in: CGRect(x: center.x - gap, y: center.y - gap, width: gap * 2, height: gap * 2))
        return context.makeImage()
    }

    /// The smallest convex polygon around the points (Andrew's monotone chain).
    static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { ($0.x, $0.y) < ($1.x, $1.y) }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for p in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// The flag emoji, trimmed to the flag itself: the glyph has margins, and shading at the
    /// edges where it waves.
    static func trimmedFlag(_ code: String) -> NSImage { trimmed(flag(code)) }

    /// Text drawn and cropped to its opaque pixels, less a margin.
    static func trimmed(_ string: String) -> NSImage {
        let text = NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: 160)])
        let size = text.size()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return NSImage() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        text.draw(at: .zero)
        NSGraphicsContext.restoreGraphicsState()

        var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = 0, maxY = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.9 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let width = Double(maxX - minX), height = Double(maxY - minY)
        let crop = CGRect(x: Double(minX) + width * 0.06, y: Double(minY) + height * 0.1, width: width * 0.88, height: height * 0.8)
        guard width > 0, height > 0, let image = rep.cgImage?.cropping(to: crop) else { return NSImage() }
        return NSImage(cgImage: image, size: crop.size)
    }

    @MainActor private static var flags: [String: NSImage] = [:]

    /// Proton's icon with a (!) in its badge, for errors and dropped connections.
    static let error: NSImage = {
        let image = NSImage(size: size, flipped: false) { rect in
            resource("disconnected").draw(in: rect)
            guard let context = NSGraphicsContext.current?.cgContext else { return true }
            let scale = rect.width / 36
            let center = CGPoint(x: 25.2 * scale, y: 25.6 * scale)
            let radius = 9.8 * scale
            context.setFillColor(NSColor.black.cgColor)
            context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.setBlendMode(.destinationOut)
            let width = 2.6 * scale
            context.addPath(CGPath(roundedRect: CGRect(x: center.x - width / 2, y: center.y - 1.2 * scale, width: width, height: 7.4 * scale),
                                   cornerWidth: width / 2, cornerHeight: width / 2, transform: nil))
            context.fillPath()
            context.fillEllipse(in: CGRect(x: center.x - width / 2, y: center.y - 5.4 * scale, width: width, height: width))
            return true
        }
        image.isTemplate = true
        return image
    }()

    static func sized(_ image: NSImage) -> NSImage {
        image.size = size
        return image
    }
}

