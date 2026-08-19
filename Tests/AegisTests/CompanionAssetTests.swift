import XCTest
import ImageIO

final class CompanionAssetTests: XCTestCase {
    private var petDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/companion/mysa")
    }

    func testMysaUsesValidatedV2AtlasGeometry() throws {
        let atlasURL = petDirectory.appendingPathComponent("spritesheet.webp")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(atlasURL as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )

        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 1536)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 2288)
    }

    func testMysaManifestDeclaresSpriteVersionTwo() throws {
        let data = try Data(contentsOf: petDirectory.appendingPathComponent("pet.json"))
        let manifest = try JSONDecoder().decode(PetManifest.self, from: data)

        XCTAssertEqual(manifest.id, "mysa")
        XCTAssertEqual(manifest.spriteVersionNumber, 2)
        XCTAssertEqual(manifest.spritesheetPath, "spritesheet.webp")
    }

    private struct PetManifest: Decodable {
        let id: String
        let spriteVersionNumber: Int
        let spritesheetPath: String
    }
}
