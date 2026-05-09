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
}
