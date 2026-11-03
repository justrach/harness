import XCTest
@testable import Harness

/// The reasoning step's slider (desktop model_preview.rs): labels per ladder, and where the thumb settles.
final class ReasoningSliderTests: XCTestCase {
    private let codex = ["low", "medium", "high", "xhigh", "max", "ultra"]

    func testAnOffHighLadderIsASwitch() {
        let ladder = ["none", "high"]
        XCTAssertTrue(ReasoningSlider.isBinary(ladder))
        XCTAssertEqual(ReasoningSlider.label("none", levels: ladder), "Off")
        XCTAssertEqual(ReasoningSlider.label("high", levels: ladder), "On")
        XCTAssertEqual(ReasoningSlider.title(ladder), "Thinking")
        XCTAssertTrue(ReasoningSlider.ends(ladder) == ("Off", "On"))
        // Any other two-level ladder is still a ladder.
        XCTAssertFalse(ReasoningSlider.isBinary(["low", "high"]))
        XCTAssertFalse(ReasoningSlider.isBinary(["none", "low", "high"]))
    }

    func testALadderReadsFasterToDeeper() {
        XCTAssertTrue(ReasoningSlider.ends(codex) == ("Faster", "Deeper"))
        XCTAssertEqual(ReasoningSlider.title(codex), "Reasoning")
        XCTAssertEqual(ReasoningSlider.label("high", levels: codex), "High")
        XCTAssertEqual(ReasoningSlider.label("xhigh", levels: codex), "X-High")
    }

    func testOneLevelOrNoneHasNothingToSlide() {
        XCTAssertFalse(ReasoningSlider.hasSlider([]))
        XCTAssertFalse(ReasoningSlider.hasSlider(["high"]))
        XCTAssertTrue(ReasoningSlider.hasSlider(["none", "high"]))
    }

    func testTheThumbSettlesOnTheNearestLevel() {
        let count = codex.count  // five gaps, 0.2 apart
        XCTAssertEqual(ReasoningSlider.nearestIndex(0, count: count), 0)
        XCTAssertEqual(ReasoningSlider.nearestIndex(0.09, count: count), 0)
        XCTAssertEqual(ReasoningSlider.nearestIndex(0.11, count: count), 1)
        XCTAssertEqual(ReasoningSlider.nearestIndex(0.5, count: count), 3)  // a tie rounds deeper
        XCTAssertEqual(ReasoningSlider.nearestIndex(1, count: count), 5)
        // Past either end the thumb stops on it.
        XCTAssertEqual(ReasoningSlider.nearestIndex(-0.4, count: count), 0)
        XCTAssertEqual(ReasoningSlider.nearestIndex(1.7, count: count), 5)
        XCTAssertEqual(ReasoningSlider.nearestIndex(0.7, count: 1), 0)
    }

    func testEachLevelHasItsPlaceOnTheTrack() {
        XCTAssertEqual(ReasoningSlider.fraction(of: 0, count: 6), 0)
        XCTAssertEqual(ReasoningSlider.fraction(of: 5, count: 6), 1)
        XCTAssertEqual(ReasoningSlider.fraction(of: 2, count: 6), 0.4, accuracy: 1e-9)
        XCTAssertEqual(ReasoningSlider.fraction(of: "high", in: codex), 0.4, accuracy: 1e-9)
        // A level this model doesn't offer starts the thumb at the left end.
        XCTAssertEqual(ReasoningSlider.fraction(of: "minimal", in: codex), 0)
        XCTAssertEqual(ReasoningSlider.fraction(of: nil, in: codex), 0)
        // Every level's place maps back to itself.
        for index in codex.indices {
            XCTAssertEqual(ReasoningSlider.nearestIndex(ReasoningSlider.fraction(of: index, count: codex.count),
                                                        count: codex.count), index)
        }
    }

    func testTheSettleIsShort() {
        XCTAssertEqual(ReasoningSlider.settle, 0.15)
    }
}
