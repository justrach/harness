import XCTest
import UIKit
@testable import Harness

final class SessionActivityAndIconTests: XCTestCase {
    private func makeChat(
        id: String,
        archived: Bool = false,
        lastMessageAt: Int64? = 1_000,
        createdAt: Int64 = 1_000,
        lastSeenAt: Int64? = 1_000
    ) -> Chat {
        Chat(
            id: id,
            deviceId: "dev-mac",
            title: id,
            archived: archived,
            cwd: "/Users/dev/harness",
            branch: "main",
            checkoutId: nil,
            config: ChatConfig(harness: "claude-code"),
            lastMessagePreview: nil,
            lastMessageAt: lastMessageAt,
            createdAt: createdAt,
            spaceId: "space-1",
            lastSeenAt: lastSeenAt,
            roomGen: 2,
            lastPromptAt: nil,
            parentChatId: nil
        )
    }

    func testSleepPresetsIncludeThisEveningBeforeSixPMAndOmitAfter() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let morning = cal.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 10, minute: 0))!
        let morningPresets = ActivitySleepRules.presets(now: morning, calendar: cal, locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertTrue(morningPresets.contains { $0.id == "this-evening" })
        XCTAssertEqual(morningPresets.map(\.until), morningPresets.map(\.until).sorted())

        let night = cal.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 20, minute: 0))!
        let nightPresets = ActivitySleepRules.presets(now: night, calendar: cal, locale: Locale(identifier: "en_US_POSIX"))
        XCTAssertFalse(nightPresets.contains { $0.id == "this-evening" })
    }

    func testWakesInCountdownAndEarlyAutoWake() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(ActivitySleepRules.wakesIn(now.addingTimeInterval(45 * 60), now: now), "45m")
        XCTAssertEqual(ActivitySleepRules.wakesIn(now.addingTimeInterval(3 * 3600 + 120), now: now), "3h")
        XCTAssertEqual(ActivitySleepRules.wakesIn(now.addingTimeInterval(2 * 86_400 + 600), now: now), "2d")

        let future = now.addingTimeInterval(3600)
        XCTAssertFalse(ActivitySleepRules.shouldAutoWake(until: future, indicator: .idle, now: now))
        XCTAssertFalse(ActivitySleepRules.shouldAutoWake(until: future, indicator: .working, now: now))
        XCTAssertTrue(ActivitySleepRules.shouldAutoWake(until: future, indicator: .awaitingInput, now: now))
        XCTAssertTrue(ActivitySleepRules.shouldAutoWake(until: future, indicator: .errored, now: now))
        XCTAssertTrue(ActivitySleepRules.shouldAutoWake(until: now.addingTimeInterval(-1), indicator: .idle, now: now))
    }

    func testArchiveGuardsBlockWorkingAndProtectActiveOrPinnedChats() {
        XCTAssertFalse(ActivitySleepRules.canManualArchive(indicator: .working))
        XCTAssertTrue(ActivitySleepRules.canManualArchive(indicator: .idle))
        XCTAssertTrue(ActivitySleepRules.canManualArchive(indicator: .completed))

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let eightDaysAgoMs = Int64((now.timeIntervalSince1970 - 8 * 86_400) * 1000)
        let oldChat = makeChat(id: "old", lastMessageAt: eightDaysAgoMs, createdAt: eightDaysAgoMs)

        XCTAssertTrue(ActivitySleepRules.archivesWhenIdle(
            chat: oldChat, indicator: .idle, isPinned: false, isOpen: false,
            isSleeping: false, wokeRecently: false, archiveAfterDays: 7, now: now
        ))
        XCTAssertFalse(ActivitySleepRules.archivesWhenIdle(
            chat: oldChat, indicator: .idle, isPinned: false, isOpen: false,
            isSleeping: false, wokeRecently: false, archiveAfterDays: 0, now: now
        ))
        XCTAssertFalse(ActivitySleepRules.archivesWhenIdle(
            chat: oldChat, indicator: .idle, isPinned: true, isOpen: false,
            isSleeping: false, wokeRecently: false, archiveAfterDays: 7, now: now
        ))
        XCTAssertFalse(ActivitySleepRules.archivesWhenIdle(
            chat: oldChat, indicator: .working, isPinned: false, isOpen: false,
            isSleeping: false, wokeRecently: false, archiveAfterDays: 7, now: now
        ))
        XCTAssertFalse(ActivitySleepRules.archivesWhenIdle(
            chat: oldChat, indicator: .idle, isPinned: false, isOpen: false,
            isSleeping: true, wokeRecently: false, archiveAfterDays: 7, now: now
        ))
    }

    @MainActor
    func testSessionSleepStorePersistenceAndAutoWake() {
        let suiteName = "HarnessTests.SessionSleepStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let until = now.addingTimeInterval(3600)
        let store = SessionSleepStore(defaults: defaults, storageKey: "test.sleep")
        store.sleep(chatId: "chat-a", until: until)
        XCTAssertTrue(store.isSleeping("chat-a"))

        let reloaded = SessionSleepStore(defaults: defaults, storageKey: "test.sleep")
        XCTAssertEqual(reloaded.sleepUntil(for: "chat-a")?.timeIntervalSince1970 ?? 0, until.timeIntervalSince1970, accuracy: 0.001)

        let chatA = makeChat(id: "chat-a")
        let woken = reloaded.autoWakeIfNeeded(chats: [chatA], indicator: { _ in .awaitingInput }, now: now)
        XCTAssertEqual(woken, ["chat-a"])
        XCTAssertFalse(reloaded.isSleeping("chat-a"))
        XCTAssertTrue(reloaded.wokeRecently("chat-a"))
    }

    func testAppIconChoiceMappingAndBundledAssets() {
        XCTAssertNil(AppIconChoice.light.alternateIconName)
        XCTAssertEqual(AppIconChoice.dark.alternateIconName, "AppIconDark")
        XCTAssertEqual(AppIconChoice.from(alternateIconName: nil), .light)
        XCTAssertEqual(AppIconChoice.from(alternateIconName: "AppIconDark"), .dark)

        XCTAssertNotNil(UIImage(named: AppIconChoice.light.previewAssetName))
        XCTAssertNotNil(UIImage(named: AppIconChoice.dark.previewAssetName))

        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let alternates = icons?["CFBundleAlternateIcons"] as? [String: Any]
        XCTAssertNotNil(alternates?["AppIconDark"])
    }

    func testPhoneOfflineStatusAndStaleMidStreamTurnGuard() {
        XCTAssertEqual(
            SendState.waitingStatusCopy(hostName: "Studio Mac", phoneOnline: false, hostOffline: true),
            "Phone is offline — waiting for connection"
        )
        XCTAssertEqual(
            SendState.waitingStatusCopy(hostName: "Studio Mac", phoneOnline: true, hostOffline: true),
            "Studio Mac is offline — will send when it reconnects"
        )
        XCTAssertEqual(
            SendState.waitingStatusCopy(hostName: "Studio Mac", phoneOnline: true, hostOffline: false),
            "Waiting for Studio Mac to start it"
        )
        XCTAssertEqual(
            describeUserFacingError(URLError(.timedOut), phoneOnline: false),
            "Phone is offline — waiting for connection"
        )

        let streamingEntry = MessageEntry(
            id: "m-1",
            role: .assistant,
            parts: [.text(id: "t-1", text: "Partial reply")],
            createdAt: 1_000,
            deviceId: "dev-mac",
            status: .streaming
        )
        XCTAssertFalse(SessionStatusWindow.hasLiveMidStreamTurn(
            entries: [streamingEntry],
            liveStatus: .idle,
            hostStatus: .online,
            nowMs: 5_000
        ))
        XCTAssertFalse(SessionStatusWindow.hasLiveMidStreamTurn(
            entries: [streamingEntry],
            liveStatus: nil,
            hostStatus: .offline,
            nowMs: 2_000
        ))
        XCTAssertFalse(SessionStatusWindow.hasLiveMidStreamTurn(
            entries: [streamingEntry],
            liveStatus: nil,
            hostStatus: .online,
            nowMs: 1_000 + SessionStatusWindow.staleStreamGraceMs + 1
        ))
        XCTAssertTrue(SessionStatusWindow.hasLiveMidStreamTurn(
            entries: [streamingEntry],
            liveStatus: .working,
            hostStatus: .online,
            nowMs: 500_000
        ))
    }
}
