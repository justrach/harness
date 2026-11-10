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

    func testCleanTopLayoutOmitsHeroAndAuxiliaryHeaderClutter() {
        XCTAssertFalse(HomeListControls.showsTopClutter(hasSessions: true))
        XCTAssertFalse(HomeListControls.showsTopClutter(hasSessions: false))
        XCTAssertFalse(SessionView.showsAuxiliaryHeaderControls(arguments: ["-demo"]))
        XCTAssertTrue(SessionView.showsAuxiliaryHeaderControls(arguments: ["-demo", "-header-status-count", "7"]))
    }

    func testActivityWindowFiltersCompletedAndIdleOutsideCutoffWhileKeepingLiveTurns() {
        let now: Int64 = 100 * 86_400_000
        let day: Int64 = 86_400_000
        func makeChat(_ id: String, daysAgo: Int64) -> Chat {
            Chat(id: id, deviceId: "studio", title: id, archived: false, cwd: nil, branch: nil,
                 checkoutId: nil, config: nil, lastMessagePreview: nil,
                 lastMessageAt: now - daysAgo * day, createdAt: now - daysAgo * day,
                 spaceId: "harness", lastSeenAt: nil)
        }
        let chats = [
            makeChat("recent-idle", daysAgo: 0),
            makeChat("old-completed", daysAgo: 5),
            makeChat("old-idle", daysAgo: 10),
            makeChat("old-working", daysAgo: 14),
            makeChat("old-awaiting", daysAgo: 20),
        ]
        let indicators: [String: ChatIndicator] = [
            "recent-idle": .idle,
            "old-completed": .completed,
            "old-idle": .idle,
            "old-working": .working,
            "old-awaiting": .awaitingInput,
        ]
        let filtered1d = HomeActivityWindow.apply(
            chats,
            window: .d1,
            indicator: { indicators[$0.id] ?? .idle },
            nowMs: now
        ).map(\.id)
        XCTAssertEqual(filtered1d, ["recent-idle", "old-working", "old-awaiting"])

        let filtered7d = HomeActivityWindow.apply(
            chats,
            window: .d7,
            indicator: { indicators[$0.id] ?? .idle },
            nowMs: now
        ).map(\.id)
        XCTAssertEqual(filtered7d, ["recent-idle", "old-completed", "old-working", "old-awaiting"])
    }

    func testTranscriptTableBatchAndIndexSafetyInvariants() {
        XCTAssertTrue(TranscriptTableView.canApplyBatchUpdate(
            uiKitRowCount: 2,
            previousIDs: ["a", "b"],
            nextIDs: ["a", "b", "c"]
        ))
        // Desynced UIKit row count after an offscreen reload must fall back to reloadData.
        XCTAssertFalse(TranscriptTableView.canApplyBatchUpdate(
            uiKitRowCount: 0,
            previousIDs: ["a", "b"],
            nextIDs: ["a", "b", "c"]
        ))
        // Duplicate IDs must fall back to reloadData rather than trapping in performBatchUpdates.
        XCTAssertFalse(TranscriptTableView.canApplyBatchUpdate(
            uiKitRowCount: 2,
            previousIDs: ["a", "a"],
            nextIDs: ["a", "b"]
        ))
        XCTAssertFalse(TranscriptTableView.canApplyBatchUpdate(
            uiKitRowCount: 2,
            previousIDs: ["a", "b"],
            nextIDs: ["a", "b", "b"]
        ))

        XCTAssertTrue(TranscriptTableView.canIndexTableRow(row: 1, rowsCount: 3, uiKitRowCount: 3))
        XCTAssertFalse(TranscriptTableView.canIndexTableRow(row: -1, rowsCount: 3, uiKitRowCount: 3))
        XCTAssertFalse(TranscriptTableView.canIndexTableRow(row: 2, rowsCount: 3, uiKitRowCount: 2))
        XCTAssertFalse(TranscriptTableView.canIndexTableRow(row: 3, rowsCount: 3, uiKitRowCount: 4))
    }

    func testTranscriptRowBuilderDisambiguatesDuplicateRowIDs() {
        let duplicateEntries = [
            MessageEntry(id: "same-entry", role: .user, parts: [.text(id: "p1", text: "First")],
                         createdAt: 1, deviceId: "d", status: .complete, continuationOf: nil),
            MessageEntry(id: "same-entry", role: .user, parts: [.text(id: "p1", text: "Second")],
                         createdAt: 2, deviceId: "d", status: .complete, continuationOf: nil),
        ]
        var parsers: [String: IncrementalMarkdownParser] = [:]
        var completed: [String: CompletedParse] = [:]
        let rows = TranscriptRowBuilder.rows(entries: duplicateEntries, pendingSends: [],
                                             parsers: &parsers, completed: &completed)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.id)).count, 2, "Duplicate entry IDs must produce unique TranscriptRow IDs")
    }

    func testUiModeStateMachineDefaultsToZenAndFlattensHierarchy() {
        XCTAssertEqual(HomeUiState.initial.mode, .zen)
        for mode in HomeUiMode.allCases {
            let state = HomeUiState(mode: mode)
            XCTAssertEqual(
                HomeListControls.stepUiState(
                    HomeListControls.stepUiState(state, .toggleMode),
                    .toggleMode
                ),
                state
            )
            XCTAssertEqual(
                HomeListControls.stepUiState(state, .resetToDefault).mode,
                .zen
            )
            XCTAssertEqual(
                HomeListControls.stepUiState(
                    HomeListControls.stepUiState(state, .setMode(mode)),
                    .setMode(mode)
                ),
                HomeListControls.stepUiState(state, .setMode(mode))
            )
        }

        let zen = HomeHierarchyProfile.ofMode(.zen)
        let dev = HomeHierarchyProfile.ofMode(.developer)
        XCTAssertEqual(zen.hierarchyDepth, 1)
        XCTAssertEqual(dev.hierarchyDepth, 4)
        XCTAssertLessThan(zen.hierarchyDepth, dev.hierarchyDepth)
        XCTAssertEqual(zen.movingPartsCount, 0)
        XCTAssertEqual(dev.movingPartsCount, 6)
        XCTAssertLessThan(zen.movingPartsCount, dev.movingPartsCount)
    }
}
