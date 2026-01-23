@testable import TimeFlipApp
import XCTest

final class AutoPauseNormalizerTests: XCTestCase {
    func testDisablesNonZeroAutoPause() async {
        let expectation = expectation(description: "setter called")

        await AutoPauseNormalizer.normalize(currentMinutes: 5) { minutes in
            XCTAssertEqual(minutes, 0)
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 0.1)
    }

    func testLeavesZeroAutoPauseUntouched() async {
        let expectation = expectation(description: "setter not called")
        expectation.isInverted = true

        await AutoPauseNormalizer.normalize(currentMinutes: 0) { _ in
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 0.1)
    }
}
