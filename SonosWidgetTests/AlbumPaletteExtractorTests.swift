import XCTest
import UIKit
@testable import SonosWidget

final class AlbumPaletteExtractorTests: XCTestCase {
    func testExtractsMultipleDistinctColorsFromStripedArtwork() throws {
        let image = makeStripedImage(colors: [.red, .green, .blue, .yellow], size: CGSize(width: 80, height: 40))

        let palette = AlbumPaletteExtractor.palette(from: image, maxColors: 4)

        XCTAssertEqual(palette.count, 4)
        XCTAssertTrue(palette.contains { $0.r > 0.8 && $0.g < 0.3 && $0.b < 0.3 })
        XCTAssertTrue(palette.contains { $0.g > 0.6 && $0.r < 0.4 && $0.b < 0.4 })
        XCTAssertTrue(palette.contains { $0.b > 0.6 && $0.r < 0.4 && $0.g < 0.4 })
    }

    func testHueXYConversionKeepsValuesInsideBridgeRange() {
        let xy = HueRGBColor(r: 1, g: 0.2, b: 0.1).xy

        XCTAssertGreaterThanOrEqual(xy.x, 0)
        XCTAssertLessThanOrEqual(xy.x, 1)
        XCTAssertGreaterThanOrEqual(xy.y, 0)
        XCTAssertLessThanOrEqual(xy.y, 1)
    }

    func testHueXYConversionUsesSafeNeutralFallbackForZeroRGB() {
        let xy = HueRGBColor(r: 0, g: 0, b: 0).xy

        XCTAssertNotEqual(xy, HueXYColor(x: 0, y: 0))
    }

    func testDefaultPaletteCapsExtractionAtFiveColors() throws {
        let image = makeStripedImage(
            colors: [.red, .green, .blue, .yellow, .magenta, .cyan],
            size: CGSize(width: 120, height: 40)
        )

        let palette = AlbumPaletteExtractor.palette(from: image)

        XCTAssertLessThanOrEqual(palette.count, 5)
    }

    func testPlainArtworkFallsBackToUsableHueColor() throws {
        let image = makeSolidImage(color: .black, size: CGSize(width: 40, height: 40))

        let palette = AlbumPaletteExtractor.palette(from: image)

        let fallbackColor = try XCTUnwrap(palette.first)
        XCTAssertGreaterThanOrEqual(fallbackColor.r, 0)
        XCTAssertGreaterThanOrEqual(fallbackColor.g, 0)
        XCTAssertGreaterThanOrEqual(fallbackColor.b, 0)
        XCTAssertNotEqual(fallbackColor.xy, HueXYColor(x: 0, y: 0))
    }

    private func makeStripedImage(colors: [UIColor], size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let stripeWidth = size.width / CGFloat(colors.count)
            for (index, color) in colors.enumerated() {
                color.setFill()
                context.fill(CGRect(x: CGFloat(index) * stripeWidth, y: 0, width: stripeWidth, height: size.height))
            }
        }
    }

    private func makeSolidImage(color: UIColor, size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
