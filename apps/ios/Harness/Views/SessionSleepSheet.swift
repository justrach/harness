// Session sleep (snooze) sheet & collapsible Asleep shelf on Home.

import SwiftUI

struct SessionSleepSheet: View {
    @Environment(\.dismiss) private var dismiss
    let chat: Chat
    let sleepStore: SessionSleepStore

    @State private var customDate: Date

    init(chat: Chat, sleepStore: SessionSleepStore) {
        self.chat = chat
        self.sleepStore = sleepStore
        let existing = sleepStore.sleepUntil(for: chat.id)
        let start = ActivitySleepRules.customStart()
        _customDate = State(initialValue: (existing.map { $0 > Date() ? $0 : start }) ?? start)
    }

    private var presets: [ActivitySleepPreset] {
        ActivitySleepRules.presets()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let currentUntil = sleepStore.sleepUntil(for: chat.id) {
                        currentSleepSection(until: currentUntil)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SheetLabel("Sleep until")
                        SheetCard {
                            ForEach(Array(presets.enumerated()), id: \.element.id) { index, preset in
                                if index > 0 { SheetSeparator() }
                                presetRow(preset)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        SheetLabel("Custom time")
                        SheetCard {
                            DatePicker(
                                "Wake at",
                                selection: $customDate,
                                in: Date()...,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                            .datePickerStyle(.graphical)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .accessibilityIdentifier("session-sleep-date-picker")
                        }

                        SheetPrimaryButton(title: "Sleep until \(formattedTime(customDate))") {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(Motion.resort) {
                                sleepStore.sleep(chatId: chat.id, until: customDate)
                            }
                            dismiss()
                        }
                        .accessibilityIdentifier("session-sleep-custom-confirm")
                    }
                }
                .padding(20)
                .padding(.bottom, 12)
            }
            .background(SheetStyle.panel)
            .navigationTitle("Sleep session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("session-sleep-sheet")
        .harnessAppearance()
    }

    private func currentSleepSection(until: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SheetLabel("Currently asleep")
            SheetCard {
                HStack(spacing: 12) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.textMuted)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chat.displayTitle)
                            .font(Theme.sans(15, weight: .medium))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                        Text("Wakes in \(ActivitySleepRules.wakesIn(until)) · \(formattedTime(until))")
                            .font(Theme.sans(12.5))
                            .foregroundStyle(Theme.textMuted)
                    }
                    Spacer(minLength: 8)
                    Button("Wake up") {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(Motion.resort) {
                            sleepStore.wake(chatId: chat.id)
                        }
                        dismiss()
                    }
                    .font(Theme.sans(14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("session-sleep-wake-now")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    private func presetRow(_ preset: ActivitySleepPreset) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            withAnimation(Motion.resort) {
                sleepStore.sleep(chatId: chat.id, until: preset.until)
            }
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text(preset.label)
                    .font(Theme.sans(15))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                Text(formattedTime(preset.until))
                    .font(Theme.sans(13))
                    .foregroundStyle(Theme.textMuted)
                Text(ActivitySleepRules.wakesIn(preset.until))
                    .font(Theme.sans(11.5, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(ink(0.06), in: Capsule())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(SheetRowButtonStyle())
        .accessibilityIdentifier("session-sleep-preset-\(preset.id)")
    }

    private func formattedTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Collapsible Asleep shelf (Home)

private extension Chat {
    var asleepShelfRowId: String { "asleep-\(id)" }
}

struct AsleepShelf: View {
    @Environment(AppModel.self) private var model
    let chats: [Chat]
    let sleepStore: SessionSleepStore
    let onSelect: (Chat) -> Void
    let onSleep: (Chat) -> Void

    @State private var open = true
    private static let rowInsets = EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14)

    var body: some View {
        if !chats.isEmpty {
            Section {
                header(count: chats.count)
                if open {
                    ForEach(chats, id: \.asleepShelfRowId) { chat in
                        row(chat)
                    }
                }
            }
        }
    }

    private func header(count: Int) -> some View {
        Button {
            withAnimation(Motion.collapse) {
                open.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Text(open ? "Asleep" : "Asleep (\(count))")
                    .font(Theme.sans(12, weight: .medium))
                    .foregroundStyle(Theme.textMuted.opacity(0.5))
                    .fixedSize()
                Rectangle()
                    .fill(Theme.border.opacity(0.6))
                    .frame(height: 1)
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textMuted.opacity(0.5))
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(open ? "Collapse asleep" : "Expand asleep, \(count) sessions")
        .accessibilityIdentifier("asleep-shelf-header")
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(Self.rowInsets)
    }

    private func row(_ chat: Chat) -> some View {
        let until = sleepStore.sleepUntil(for: chat.id)
        let canArchive = ActivitySleepRules.canManualArchive(indicator: model.indicator(for: chat))
        return Button {
            onSelect(chat)
        } label: {
            HStack(spacing: 10) {
                if let harness = chat.config?.harness {
                    HarnessBadge(harness: harness, size: 14, dimmed: true)
                }
                Text(chat.displayTitle)
                    .font(Theme.sans(15))
                    .foregroundStyle(Theme.text.opacity(0.65))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let until {
                    HStack(spacing: 4) {
                        Image(systemName: "moon.zzz")
                            .font(.system(size: 10, weight: .medium))
                        Text(ActivitySleepRules.wakesIn(until))
                            .font(Theme.sans(12, weight: .medium))
                            .monospacedDigit()
                    }
                    .foregroundStyle(Theme.textMuted.opacity(0.75))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(ink(0.05), in: Capsule())
                    .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(PressWashButtonStyle())
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(Self.rowInsets)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                withAnimation(Motion.resort) {
                    sleepStore.wake(chatId: chat.id)
                }
            } label: {
                Label("Wake up", systemImage: "sun.max")
            }
            .tint(Theme.accent)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: canArchive) {
            Button {
                guard ActivitySleepRules.canManualArchive(indicator: model.indicator(for: chat)) else { return }
                withAnimation(Motion.resort) {
                    sleepStore.wake(chatId: chat.id, markWokeRecently: false)
                    model.archive(chatId: chat.id)
                }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(Theme.surfaceRaised)
            .disabled(!canArchive)
        }
        .contextMenu {
            Button("Wake up", systemImage: "sun.max") {
                withAnimation(Motion.resort) {
                    sleepStore.wake(chatId: chat.id)
                }
            }
            Button("Sleep…", systemImage: "moon.zzz") {
                onSleep(chat)
            }
            Button("Archive", systemImage: "archivebox") {
                guard ActivitySleepRules.canManualArchive(indicator: model.indicator(for: chat)) else { return }
                withAnimation(Motion.resort) {
                    sleepStore.wake(chatId: chat.id, markWokeRecently: false)
                    model.archive(chatId: chat.id)
                }
            }
            .disabled(!canArchive)
        }
        .accessibilityIdentifier("asleep-row-\(chat.id)")
    }
}
