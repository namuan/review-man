import XCTest
@testable import PRReviewDesktop

final class CanvasWheelZoomTests: XCTestCase {
    func testDiscreteMouseWheelAdjustsCanvasZoom() {
        XCTAssertEqual(
            CanvasWheelZoom.adjustedZoom(
                currentZoom: 0.85,
                scrollingDeltaY: 1,
                hasPreciseScrollingDeltas: false
            ),
            0.95
        )
        XCTAssertEqual(
            CanvasWheelZoom.adjustedZoom(
                currentZoom: 0.85,
                scrollingDeltaY: -1,
                hasPreciseScrollingDeltas: false
            ),
            0.75
        )
    }

    func testTrackpadAndBoundedWheelEventsPassThrough() {
        XCTAssertNil(CanvasWheelZoom.adjustedZoom(
            currentZoom: 0.85,
            scrollingDeltaY: 1,
            hasPreciseScrollingDeltas: true
        ))
        XCTAssertNil(CanvasWheelZoom.adjustedZoom(
            currentZoom: ChangeCanvasView.maximumZoom,
            scrollingDeltaY: 1,
            hasPreciseScrollingDeltas: false
        ))
    }
}
