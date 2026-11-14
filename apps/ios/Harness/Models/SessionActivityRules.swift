// Session activity rules — snooze ("Sleep") presets, wake-up conditions,
// working-archive guard, and idle auto-archive sweep.

import Foundation
import Observation

struct ActivitySleepPreset: Identifiable, Equatable {
    let id: String
    let label: String
    let until: Date
}

enum ActivitySleepRules {
    static let archiveAfterKey = "activity.archiveAfter"
    static let archiveAfterChoices = [0, 1, 3, 7, 14, 30]

    static func archiveAfterLabel(_ days: Int) -> String {
        if days <= 0 { return "Never" }
        return days == 1 ? "After 1 Day" : "After \(days) Days"
    }

    static func presets(
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> [ActivitySleepPreset] {
        var cal = calendar
        cal.locale = locale

        var candidates: [ActivitySleepPreset] = []

        if let inOneHour = cal.date(byAdding: .hour, value: 1, to: now) {
            candidates.append(ActivitySleepPreset(id: "in-1h", label: "In 1 Hour", until: inOneHour))
        }
        if let inThreeHours = cal.date(byAdding: .hour, value: 3, to: now) {
            candidates.append(ActivitySleepPreset(id: "in-3h", label: "In 3 Hours", until: inThreeHours))
        }
        if let thisEvening = cal.date(bySettingHour: 18, minute: 0, second: 0, of: now),
           thisEvening > now {
            candidates.append(ActivitySleepPreset(id: "this-evening", label: "This Evening", until: thisEvening))
        }

        let startOfToday = cal.startOfDay(for: now)
        if let tomorrowStart = cal.date(byAdding: .day, value: 1, to: startOfToday) {
            if let tomorrowMorning = cal.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrowStart) {
                candidates.append(ActivitySleepPreset(id: "tomorrow", label: "Tomorrow", until: tomorrowMorning))
            }
            if let nextMonday = cal.nextDate(
                after: tomorrowStart,
                matching: DateComponents(hour: 9, minute: 0, second: 0, weekday: 2),
                matchingPolicy: .nextTime
            ) {
                candidates.append(ActivitySleepPreset(id: "next-week", label: "Next Week", until: nextMonday))
            }
        }

        let sorted = candidates.sorted { $0.until < $1.until }
        var seenMinutes = Set<Int64>()
        var unique: [ActivitySleepPreset] = []
        for preset in sorted {
            let minuteBucket = Int64(floor(preset.until.timeIntervalSince1970 / 60))
            if seenMinutes.insert(minuteBucket).inserted {
                unique.append(preset)
            }
        }
        return unique
    }

    static func customStart(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let oneHourAhead = calendar.date(byAdding: .hour, value: 1, to: now) ?? now.addingTimeInterval(3600)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: oneHourAhead)
        let clean = calendar.date(from: components) ?? oneHourAhead
        return clean > now ? clean : oneHourAhead
    }

    static func wakesIn(_ until: Date, now: Date = Date()) -> String {
        let secs = until.timeIntervalSince(now)
        if secs <= 0 { return "0m" }
        if secs < 3600 {
            let mins = max(1, Int(ceil(secs / 60)))
            return "\(mins)m"
        }
        if secs < 86_400 {
            let hours = max(1, Int(secs / 3600))
            return "\(hours)h"
        }
        let days = max(1, Int(secs / 86_400))
        return "\(days)d"
    }

    static func shouldAutoWake(until: Date, indicator: ChatIndicator, now: Date = Date()) -> Bool {
        now >= until || indicator == .awaitingInput || indicator == .errored
    }

    static func canManualArchive(indicator: ChatIndicator) -> Bool {
        indicator != .working
    }

    static func archivesWhenIdle(
        chat: Chat,
        indicator: ChatIndicator,
        isPinned: Bool,
        isOpen: Bool,
        isSleeping: Bool,
        wokeRecently: Bool,
        archiveAfterDays: Int,
        now: Date = Date()
    ) -> Bool {
        guard !chat.archived, archiveAfterDays > 0 else { return false }
        guard !isPinned, !isOpen, !isSleeping, !wokeRecently else { return false }
        switch indicator {
        case .working, .awaitingInput, .errored:
            return false
        case .completed, .idle:
            break
        }
        let lastTouchedMs = max(chat.calledAt, chat.lastMessageAt ?? 0)
        let cutoffMs = Int64(archiveAfterDays) * 86_400_000
        let currentMs = Int64(now.timeIntervalSince1970 * 1000)
        return (currentMs - lastTouchedMs) >= cutoffMs
    }
}

@MainActor
@Observable
final class SessionSleepStore {
    static let shared = SessionSleepStore()
    nonisolated static let storageKey = "activity.sleepingSessions"

    private(set) var sleepingUntil: [String: Date] = [:]
    private(set) var recentlyWokenIds: Set<String> = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String

    init(defaults: UserDefaults = .standard, storageKey: String = SessionSleepStore.storageKey) {
        self.defaults = defaults
        self.storageKey = storageKey
        load()
    }

    func sleep(chatId: String, until: Date) {
        sleepingUntil[chatId] = until
        recentlyWokenIds.remove(chatId)
        save()
    }

    func wake(chatId: String, markWokeRecently: Bool = true) {
        let removed = sleepingUntil.removeValue(forKey: chatId) != nil
        if markWokeRecently {
            recentlyWokenIds.insert(chatId)
        }
        if removed {
            save()
        }
    }

    func sleepUntil(for chatId: String) -> Date? {
        sleepingUntil[chatId]
    }

    func isSleeping(_ chatId: String) -> Bool {
        sleepingUntil[chatId] != nil
    }

    func wokeRecently(_ chatId: String) -> Bool {
        recentlyWokenIds.contains(chatId)
    }

    @discardableResult
    func autoWakeIfNeeded(
        chats: [Chat],
        indicator: (Chat) -> ChatIndicator,
        now: Date = Date()
    ) -> [String] {
        guard !sleepingUntil.isEmpty else { return [] }
        let byId = Dictionary(uniqueKeysWithValues: chats.map { ($0.id, $0) })
        var woken: [String] = []
        for (chatId, until) in sleepingUntil {
            if let chat = byId[chatId] {
                if chat.archived || ActivitySleepRules.shouldAutoWake(
                    until: until,
                    indicator: indicator(chat),
                    now: now
                ) {
                    woken.append(chatId)
                }
            } else if now >= until {
                woken.append(chatId)
            }
        }
        for id in woken {
            sleepingUntil.removeValue(forKey: id)
            recentlyWokenIds.insert(id)
        }
        if !woken.isEmpty {
            save()
        }
        return woken
    }

    private func load() {
        guard let raw = defaults.dictionary(forKey: storageKey) as? [String: Double] else {
            sleepingUntil = [:]
            return
        }
        sleepingUntil = raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private func save() {
        if sleepingUntil.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else {
            let encoded = sleepingUntil.mapValues { $0.timeIntervalSince1970 }
            defaults.set(encoded, forKey: storageKey)
        }
    }
}
