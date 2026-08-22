import XCTest
@testable import PRReviewDesktop

final class CanvasFitTests: XCTestCase {
    func testProvisionalViewportIsNotAccepted() {
        XCTAssertNil(ChangeCanvasView.fittedZoom(
            board: CGSize(width: 270, height: 134),
            viewport: CGSize(width: 282.5, height: 3)
        ))
    }

    func testSettledViewportFitsCollapsedBoard() {
        XCTAssertEqual(
            ChangeCanvasView.fittedZoom(
                board: CGSize(width: 270, height: 134),
                viewport: CGSize(width: 1_552, height: 981)
            ),
            ChangeCanvasView.maximumZoom
        )
    }

    func testFitUsesBoardAndViewportDimensions() {
        let zoom = ChangeCanvasView.fittedZoom(
            board: CGSize(width: 568, height: 964),
            viewport: CGSize(width: 1_552, height: 981)
        )
        XCTAssertEqual(zoom ?? 0, 0.925_373_443_983_402_5, accuracy: 0.000_001)
    }
}
