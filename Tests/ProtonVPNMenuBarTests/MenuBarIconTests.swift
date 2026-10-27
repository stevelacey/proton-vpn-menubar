import AppKit
import Testing
@testable import ProtonVPNMenuBar

/// Draws an image into a bitmap, in light or dark mode, returning how many pixels it painted.
@MainActor func painted(_ image: NSImage, dark: Bool = false) -> Int {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 36, height: 36))
        NSGraphicsContext.restoreGraphicsState()
    }
    return (0..<36).flatMap { y in (0..<36).map { (x: $0, y: y) } }
        .filter { (rep.colorAt(x: $0.x, y: $0.y)?.alphaComponent ?? 0) > 0 }.count
}

/// Runs an image's drawing handler without a graphics context, as it would be with nowhere to draw.
@MainActor func drawsNothingWithoutAContext(_ image: NSImage) -> Bool {
    NSGraphicsContext.current = nil
    return (image.representations.first as? NSCustomImageRep)?.drawingHandler?(NSRect(x: 0, y: 0, width: 18, height: 18)) == true
}

@MainActor @Suite(.serialized) struct MenuBarIconTests {
    init() { resourceDirectory = repoResources }

    @Test func protonsIconsAtMenuBarSize() {
        #expect(MenuBarIcon.connected.size == MenuBarIcon.size)
        #expect(MenuBarIcon.disconnected.size == MenuBarIcon.size)
        #expect(painted(MenuBarIcon.connected) > 0)
    }

    @Test func connectingFramesHighlightEachDot() {
        let frames = MenuBarIcon.connecting
        #expect(frames.count == 3 && frames.allSatisfy(\.isTemplate))
        #expect(frames.map { painted($0) }.allSatisfy { $0 > 0 })
        #expect(drawsNothingWithoutAContext(frames[0]))
    }

    @Test func errorIcon() {
        #expect(MenuBarIcon.error.isTemplate)
        #expect(painted(MenuBarIcon.error) > 0)
        #expect(drawsNothingWithoutAContext(MenuBarIcon.error))
    }

    @Test func flaggedIconIsCachedAndDrawnForEitherMenuBar() {
        let swiss = MenuBarIcon.flagged("CH")
        #expect(!swiss.isTemplate)
        #expect(MenuBarIcon.flagged("CH") === swiss)
        #expect(painted(swiss) > 0)
        #expect(painted(swiss, dark: true) > 0)
        #expect(drawsNothingWithoutAContext(swiss))
    }

    @Test func solidTriangleNeedsProtonsIcon() {
        #expect(MenuBarIcon.solidTriangle != nil)
        #expect(MenuBarIcon.makeSolidTriangle(from: NSImage()) == nil)
    }

    @Test func trimsFlagsToTheirPixels() {
        let flag = MenuBarIcon.trimmedFlag("CH")
        #expect(flag.size.width > 0 && flag.size.width < 160)
        #expect(MenuBarIcon.trimmed("").size == .zero)
        #expect(MenuBarIcon.trimmed(" ").size == .zero)
    }

    @Test func convexHull() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 2, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2), CGPoint(x: 0, y: 2)]
        #expect(MenuBarIcon.convexHull(points) == [CGPoint(x: 0, y: 0), CGPoint(x: 2, y: 0), CGPoint(x: 2, y: 2), CGPoint(x: 0, y: 2)])
    }
}
