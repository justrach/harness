import XCTest
@testable import Harness

/// The Home list's project and grouping pills (#419).
final class HomeListControlsTests: XCTestCase {
    func testProjectPillNamesAllProjectsOrTheChosenProject() {
        XCTAssertEqual(HomeListControls.scopeTitle(projectName: nil), "All projects")
        XCTAssertEqual(HomeListControls.scopeTitle(projectName: ""), "All projects")
        XCTAssertEqual(HomeListControls.scopeTitle(projectName: "harness"), "harness")
    }

    func testGroupingPillSaysItArrangesTheList() {
        XCTAssertEqual(HomeGroupBy.status.pillTitle, "By status")
        XCTAssertEqual(HomeGroupBy.none.pillTitle, "By time")
        XCTAssertEqual(HomeGroupBy.project.pillTitle, "By project")
        XCTAssertEqual(HomeGroupBy.device.pillTitle, "By device")
        // The menu's choices and the accessibility value keep the short names.
        XCTAssertEqual(HomeGroupBy.allCases.map(\.label), ["Status", "Time", "Project", "Device"])
    }

    func testRowShowsWhileThereIsAnythingToScope() {
        XCTAssertTrue(HomeListControls.showsRow(hasSessions: true, hasProjects: false, projectSelected: false))
        XCTAssertTrue(HomeListControls.showsRow(hasSessions: false, hasProjects: true, projectSelected: false))
        // Nothing yet: onboarding owns the screen.
        XCTAssertFalse(HomeListControls.showsRow(hasSessions: false, hasProjects: false, projectSelected: false))
    }

    /// A chosen project with no sessions must keep its pill, or there is no way
    /// back to All projects from the empty list.
    func testAChosenEmptyProjectKeepsTheRow() {
        XCTAssertTrue(HomeListControls.showsRow(hasSessions: false, hasProjects: false, projectSelected: true))
        XCTAssertFalse(HomeListControls.showsGrouping(sessionsInScope: 0))
        XCTAssertTrue(HomeListControls.showsGrouping(sessionsInScope: 3))
    }
}
