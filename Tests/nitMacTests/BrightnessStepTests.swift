import XCTest
@testable import nitMac

final class BrightnessStepTests: XCTestCase {
    func testStopsSpanTheWholeRangeInSixteenSteps() {
        XCTAssertEqual(BrightnessStep.stops.count, BrightnessStep.divisions + 1)
        XCTAssertEqual(BrightnessStep.stops.first, 0)
        XCTAssertEqual(BrightnessStep.stops.last, 100)
        XCTAssertEqual(BrightnessStep.stops, BrightnessStep.stops.sorted())
    }

    func testEachPressMovesOneStop() {
        XCTAssertEqual(step(from: 50, .up), 56)
        XCTAssertEqual(step(from: 56, .down), 50)
    }

    func testTheEndsOfTheRangeAreStops() {
        XCTAssertEqual(step(from: 94, .up), 100)
        XCTAssertEqual(step(from: 6, .down), 0)
    }

    func testSteppingPastTheEndsHoldsStill() {
        XCTAssertEqual(step(from: 100, .up), 100)
        XCTAssertEqual(step(from: 0, .down), 0)
    }

    /// A brightness set from System Settings or another app rarely sits on the
    /// grid; the next press should join the grid rather than jump across it.
    func testOffGridValuesJoinTheNearestStopInTheDirectionOfTravel() {
        XCTAssertEqual(step(from: 32, .up), 38)
        XCTAssertEqual(step(from: 32, .down), 31)
    }

    func testFineAdjustmentMovesASinglePercent() {
        XCTAssertEqual(step(from: 32, .up, fine: true), 33)
        XCTAssertEqual(step(from: 32, .down, fine: true), 31)
        XCTAssertEqual(step(from: 100, .up, fine: true), 100)
        XCTAssertEqual(step(from: 0, .down, fine: true), 0)
    }

    func testValuesOutsideTheRangeAreBroughtBackIntoIt() {
        XCTAssertEqual(step(from: 140, .down), 94)
        XCTAssertEqual(step(from: -20, .up), 6)
    }

    private func step(from percent: Int, _ direction: BrightnessDirection, fine: Bool = false) -> Int {
        BrightnessStep.next(percent: percent, direction: direction, fine: fine)
    }
}
