// Space detail — the phone's answer to the desktop's horizontal session tabs:
// the space's sessions as a vertical list (creation order, like tab order),
// swipe-to-archive (= tab close), and "+" to start a session in this space.

import os
import SwiftUI

struct SpaceView: View {
    @Environment(AppModel.self) private var model
    let spaceId: String
    @Binding var path: [Route]
    /// A session whose Delete is waiting on its confirmation.
    @State private var pendingDelete: Chat?

    private var space: Space? {
        model.spaces.first { $0.id == spaceId }
    }

    var body: some View {
        List {
            let chats = model.chats(in: spaceId)
            if chats.isEmpty {
                emptyState
            }
            ForEach(chats) { chat in
                ChatRow(chat: chat, showLocation: true) {
                    path.append(.chat(chat.id))
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 1, leading: 12, bottom: 1, trailing: 12))
                .sessionPinAction(chat: chat, model: model)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button {
                        withAnimation(Motion.resort) {
                            model.archive(chatId: chat.id)
                        }
                    } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    .tint(Theme.surfaceRaised)
                    // No destructive role: SwiftUI would slide the row out
                    // before the confirmation is answered.
                    Button {
                        pendingDelete = chat
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(Theme.danger)
                    .accessibilityIdentifier("session-delete")
                }
            }
            ArchivedSection(spaceId: spaceId, path: $path)
        }
        .sessionDeleteConfirmation(pending: $pendingDelete) { chat in
            withAnimation(Motion.resort) {
                model.delete(chatId: chat.id)
            }
            path.removeAll { $0 == .chat(chat.id) }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 10)
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(Theme.surface.ignoresSafeArea())
        .navigationTitle(space?.displayName ?? "Space")  // feeds the back menu
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(space?.displayName ?? "Space")
                        .font(Theme.sans(13, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if let space {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                                .font(.system(size: 9))
                            Text("\(space.path) · \(model.deviceName(space.deviceId))")
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        .font(Theme.sans(10.5))
                        .foregroundStyle(Theme.textMuted.opacity(0.6))
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    path.append(.newSession(spaceId: spaceId))
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New session")
            }
        }
        .onAppear {
            if model.launchSheet == "newsession" {
                model.launchSheet = nil
                path.append(.newSession(spaceId: spaceId))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.textFaint)
            Text("No sessions in this space")
                .font(Theme.sans(13))
                .foregroundStyle(Theme.textFaint)
            Button {
                path.append(.newSession(spaceId: spaceId))
            } label: {
                Text("Start a session")
                    .font(Theme.sans(13, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
            }
            .buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private func shortPath(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}


// MARK: - New space: remote folder browser

private let folderLog = Logger(subsystem: "harness.codegraff.ios", category: "folders")

/// The desktop add-space palette translated to a sheet: device tabs, mono
/// breadcrumb with an up button, the device's folders (git repos badged),
/// "Use this folder" pinned at the bottom. Listing comes from the device over
/// the relay (ListFolders); dotfiles are pre-filtered and long listings are
/// truncated at 500 by the engine. Folders already visited come from
/// `FolderBrowserState`'s cache instead of another round trip (#420).
struct NewSpaceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onCreated: (String) -> Void

    @State private var deviceId: String?
    @State private var browser = FolderBrowserState()
    @State private var navigationTask: Task<Void, Never>?
    @State private var creating = false
    @State private var query = ""

    private var devices: [DeviceRow] {
        model.executionDevices
    }

    private var selectedDeviceId: String? {
        if let deviceId {
            // A removed host must not leave its folders usable, or silently
            // redirect creation to a different computer.
            return devices.contains { $0.id == deviceId } ? deviceId : nil
        }
        return devices.first?.id
    }

    private var listing: FolderListing? {
        browser.selection(for: selectedDeviceId)?.listing
    }

    private var loading: Bool { browser.isLoading }
    private var error: String? {
        browser.deviceId == selectedDeviceId ? browser.error : nil
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                if devices.isEmpty {
                    emptyDevices
                } else {
                    deviceTabs
                        .padding(.horizontal, 20)
                        .padding(.top, 6)
                        .padding(.bottom, 14)
                    breadcrumbBar
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                    folderList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(SheetStyle.panel)
            .navigationTitle("New space")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search this folder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .accessibilityLabel("Close")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !devices.isEmpty {
                    useFolderButton
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                        .padding(.bottom, 6)
                        .background(SheetStyle.panel.opacity(0.94))
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .harnessAppearance()
        .task(id: selectedDeviceId) {
            // Hold on to the computer the sheet opened on: falling back to "the
            // first device" let a re-sorted device list switch computers and
            // reload the listing from the top while someone was browsing.
            guard !Task.isCancelled else { return }
            let host = selectedDeviceId
            if deviceId == nil { deviceId = host }
            navigationTask?.cancel()
            // Folders loaded in an earlier presentation show straight away.
            browser.cache = model.folderListings
            browser.selectDevice(host)
            guard let request = browser.begin(path: nil) else { return }
            await load(request)
        }
        .onDisappear {
            navigationTask?.cancel()
            browser.cancelPendingRequest()
        }
    }

    // MARK: Pieces

    private var deviceTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(devices) { device in
                    let selected = device.id == selectedDeviceId
                    Button {
                        guard !creating, selectedDeviceId != device.id else { return }
                        UISelectionFeedbackGenerator().selectionChanged()
                        navigationTask?.cancel()
                        browser.selectDevice(device.id)
                        deviceId = device.id
                        query = ""
                    } label: {
                        HStack(spacing: 7) {
                            Circle()
                                .fill(model.deviceOnline(device.id)
                                    ? Theme.statusCompleted.opacity(0.9) : ink(0.18))
                                .frame(width: 6, height: 6)
                            Text(device.name)
                                .font(Theme.sans(13, weight: .medium))
                                .foregroundStyle(selected ? Theme.text : Theme.textMuted)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(selected ? ink(0.15) : ink(0.05), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(creating)
                }
            }
        }
    }

    private var breadcrumbBar: some View {
        HStack(spacing: 10) {
            Button {
                if let parent = listing?.parent {
                    navigate(path: parent, isRepo: false)
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(listing?.parent == nil ? Theme.textFaint.opacity(0.4) : Theme.text)
                    .frame(width: 32, height: 32)
                    .background(ink(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(listing?.parent == nil || creating)
            .accessibilityLabel("Up")
            .accessibilityIdentifier("folder-up")

            Text(listing?.path ?? " ")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("folder-path")

            if loading {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Theme.textMuted)
                    .accessibilityIdentifier("folder-loading")
            }
        }
    }

    private var folderList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let error {
                    Text(error)
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.danger)
                        .padding(.horizontal, 4)
                }
                let needle = query.trimmingCharacters(in: .whitespaces)
                let folders = (listing?.entries ?? []).filter {
                    $0.isDir && (needle.isEmpty || $0.name.localizedCaseInsensitiveContains(needle))
                }
                if folders.isEmpty, !loading, error == nil, listing != nil {
                    Text(needle.isEmpty ? "No folders here" : "No folders match \u{201C}\(needle)\u{201D}")
                        .font(Theme.sans(13))
                        .foregroundStyle(Theme.textFaint)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                }
                if !folders.isEmpty {
                    SheetCard {
                        ForEach(Array(folders.enumerated()), id: \.element.name) { ix, entry in
                            folderRow(entry)
                            if ix < folders.count - 1 {
                                SheetSeparator()
                            }
                        }
                    }
                }
                if listing?.truncated == true {
                    Text("Listing truncated — this folder has more entries.")
                        .font(Theme.sans(12))
                        .foregroundStyle(Theme.textFaint)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .opacity(loading && listing == nil ? 0.4 : 1)
        .refreshable {
            await refresh()
        }
    }

    private func folderRow(_ entry: FolderEntry) -> some View {
        Button {
            guard let base = listing?.path else { return }
            let child = base.hasSuffix("/") ? base + entry.name : "\(base)/\(entry.name)"
            navigate(path: child, isRepo: entry.isRepo)
        } label: {
            HStack(spacing: 12) {
                LineIconView(entry.isRepo ? .folderWithFiles : .folder, size: 16,
                             color: entry.isRepo ? Theme.accent.opacity(0.85) : Theme.textMuted)
                    .frame(width: 22)
                Text(entry.name)
                    .font(Theme.sans(15))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if entry.isRepo {
                    Text("git")
                        .font(Theme.mono(10))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .tintedChip(Theme.accent)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(SheetRowButtonStyle())
        .disabled(creating)
        .accessibilityIdentifier("folder-row-\(entry.name)")
    }

    private var useFolderButton: some View {
        let name = (listing?.path as NSString?)?.lastPathComponent ?? ""
        return SheetPrimaryButton(
            title: creating ? "Creating…" : (name.isEmpty ? "Use this folder" : "Use “\(name)”"),
            enabled: browser.creationTarget(for: selectedDeviceId) != nil && !creating
        ) {
            create()
        }
    }

    private var emptyDevices: some View {
        VStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.textFaint)
            Text("No devices yet")
                .font(Theme.sans(15, weight: .medium))
                .foregroundStyle(Theme.text)
            Text("Run Harness on a computer first — its folders will show up here.")
                .font(Theme.sans(13))
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    // MARK: Data

    /// Never waits on the host: a cached folder shows at once (and refreshes
    /// in the background when it's older), and the latest tap always wins.
    private func navigate(path: String, isRepo: Bool) {
        guard !creating, browser.deviceId == selectedDeviceId else { return }
        navigationTask?.cancel()
        navigationTask = nil
        guard let request = browser.begin(path: path, isRepo: isRepo) else { return }
        navigationTask = Task { await load(request) }
    }

    /// Pull to refresh: ask the host for the folder on screen even when its
    /// listing is fresh.
    private func refresh() async {
        guard !creating, let current = browser.selection(for: selectedDeviceId) else { return }
        navigationTask?.cancel()
        navigationTask = nil
        guard let request = browser.begin(path: current.listing.path, isRepo: current.isRepo,
                                          refresh: true) else { return }
        await load(request)
    }

    private func load(_ request: FolderBrowserState.Request) async {
        guard !Task.isCancelled else {
            browser.finish(request, listing: nil, currentDeviceId: selectedDeviceId,
                           cancelled: true, failureMessage: "")
            return
        }
        let started = ContinuousClock.now
        var listing: FolderListing?
        var failure = ""
        do {
            listing = try await model.listFolders(deviceId: request.deviceId, path: request.path)
        } catch {
            // Say why, even when an older listing stays on screen.
            failure = "Couldn't open that folder on \(model.deviceName(request.deviceId)): "
                + describeUserFacingError(error)
        }
        // End to end (relay included); the host logs its own walk time.
        let ms = Int((ContinuousClock.now - started) / .milliseconds(1))
        let mode = request.revalidating ? "refresh" : "cold"
        let outcome = listing == nil ? "failed" : "ok"
        folderLog.info("ListFolders \(mode, privacy: .public) \(outcome, privacy: .public) in \(ms) ms")
        withAnimation(Motion.fadeQuick) {
            _ = browser.finish(request, listing: listing, currentDeviceId: selectedDeviceId,
                               cancelled: Task.isCancelled, failureMessage: failure)
        }
    }

    private func create() {
        guard !creating, let target = browser.creationTarget(for: selectedDeviceId) else { return }
        creating = true
        // Capture host, path and Git metadata from the same successful listing,
        // rather than combining a current host with an earlier host's reply.
        Task {
            let id = await model.createSpace(deviceId: target.deviceId,
                                             path: target.listing.path, gitDetected: target.isRepo)
            creating = false
            if let id {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                dismiss()
                onCreated(id)
            }
        }
    }
}
