import XCTest
@testable import ThirdHand

final class OnboardingResourceTests: XCTestCase {
    func testOnboardingVideoIsBundled() throws {
        let url = try XCTUnwrap(OnboardingVideoResource.url)
        let values = try url.resourceValues(forKeys: [.fileSizeKey])

        XCTAssertEqual(url.pathExtension.lowercased(), "mov")
        XCTAssertGreaterThan(values.fileSize ?? 0, 1_000_000)
    }

    func testReducedMotionPosterIsBundled() throws {
        let url = try XCTUnwrap(OnboardingVideoResource.posterURL)
        let values = try url.resourceValues(forKeys: [.fileSizeKey])

        XCTAssertEqual(url.pathExtension.lowercased(), "png")
        XCTAssertGreaterThan(values.fileSize ?? 0, 100_000)
    }
}
