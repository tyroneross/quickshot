import AppKit
import Testing
@testable import QuickShot

/// Measures the text colours the views draw against the surfaces they sit on,
/// in both appearances, using the WCAG contrast formula.
@MainActor
@Suite struct ContrastTests {
    struct RGB { var r, g, b: Double }

    static func resolve(_ color: NSColor, in appearance: NSAppearance) -> (rgb: RGB, alpha: Double) {
        var result: (RGB, Double) = (RGB(r: 0, g: 0, b: 0), 1)
        appearance.performAsCurrentDrawingAppearance {
            let c = color.usingColorSpace(.sRGB) ?? .black
            result = (RGB(r: c.redComponent, g: c.greenComponent, b: c.blueComponent), c.alphaComponent)
        }
        return result
    }

    static func blend(_ top: RGB, alpha: Double, over bottom: RGB) -> RGB {
        RGB(r: top.r * alpha + bottom.r * (1 - alpha),
            g: top.g * alpha + bottom.g * (1 - alpha),
            b: top.b * alpha + bottom.b * (1 - alpha))
    }

    static func luminance(_ c: RGB) -> Double {
        func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b)
    }

    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// The window surface, and that surface under a tint of `color`.
    static func surfaces(in appearance: NSAppearance) -> [(name: String, rgb: RGB)] {
        let window = resolve(.windowBackgroundColor, in: appearance).rgb
        let tints: [(String, NSColor)] = [
            ("accent tint", .controlAccentColor), ("orange tint", .systemOrange), ("red tint", .systemRed),
        ]
        return [("window", window)] + tints.map { name, color in
            (name, blend(resolve(color, in: appearance).rgb, alpha: Palette.tintOpacity, over: window))
        }
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func textMeetsFourPointFiveToOneOnEverySurface(appearanceName: NSAppearance.Name) throws {
        let appearance = try #require(NSAppearance(named: appearanceName))
        let label = Self.resolve(.labelColor, in: appearance)

        for surface in Self.surfaces(in: appearance) {
            let body = Self.blend(label.rgb, alpha: label.alpha, over: surface.rgb)
            let supporting = Self.blend(label.rgb, alpha: label.alpha * Palette.supportingTextOpacity, over: surface.rgb)
            let bodyRatio = Self.contrast(body, surface.rgb)
            let supportingRatio = Self.contrast(supporting, surface.rgb)
            print("contrast \(appearanceName.rawValue) \(surface.name): body \(String(format: "%.2f", bodyRatio)), supporting \(String(format: "%.2f", supportingRatio))")
            #expect(bodyRatio >= 4.5, "body text on \(surface.name)")
            #expect(supportingRatio >= 4.5, "supporting text on \(surface.name)")
        }
    }

    /// Records why the views do not use the system secondary colour.
    @Test func systemSecondaryTextIsMeasuredNotAssumed() throws {
        let appearance = try #require(NSAppearance(named: .aqua))
        let window = Self.resolve(.windowBackgroundColor, in: appearance).rgb
        let secondary = Self.resolve(.secondaryLabelColor, in: appearance)
        let ratio = Self.contrast(Self.blend(secondary.rgb, alpha: secondary.alpha, over: window), window)
        print("contrast aqua window: system secondary \(String(format: "%.2f", ratio))")
        #expect(ratio > 1)
    }
}
