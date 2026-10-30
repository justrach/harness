// New session — a real composer page, not a form. Mirrors the old mobile
// app's canvas (faded mark + "What are we building?" + glass composer with
// picker chips) and the desktop's new-session canvas (composer expanded with
// in-pill pickers). The destination fixes a project or execution host; the composer
// carries the agent/model chip, and sending mints the chat, queues the first
// run, and swaps straight into the live session.

import PhotosUI
import SwiftUI

struct NewSessionView: View {
    @Environment(AppModel.self) private var model
    let destination: NewSessionDestination
    @Binding var path: [Route]

    // Sticky run config (the old app persisted these to prefs.db).
    @AppStorage("newSessionHarness") private var harness = "claude-code"
    @AppStorage("newSessionModel") private var storedModel = ""
    @AppStorage("newSessionReasoning") private var storedReasoning = ""
    /// Chat mode keeps its own pick, so it never changes the coding defaults.
    @AppStorage("newChatModel") private var storedChatModel = ""

    @State private var draft: String
    @State private var selectedHostId: String?
    @State private var showHostPicker = false
    @State private var showPicker = false
    @State private var showTraitPicker = false
    @State private var showOptionPicker: ModelOptionInfo?
    @State private var showRefPicker = false
    /// The last refused checkout from the ref picker (#424).
    @State private var refFailure: RefCheckoutFailure?
    @State private var showCheckoutPicker = false
    @State private var attachments: [StagedAttachment] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var attachError: String?
    /// Only agents actually discovered on this device are offered.
    @State private var liveHarnesses: [HarnessInfo]?
    /// Live or cached metadata, scoped to the execution device.
    @State private var catalogs: [String: [ModelInfo]] = [:]
    @State private var catalogsLoading = true
    @State private var catalogRetry = 0
    @State private var confirmedHarnesses: [HarnessInfo]?
    @State private var confirmedCatalogs: [String: [ModelInfo]] = [:]
    @State private var optionSelections: [String: String] = [:]
    /// Never expose a previous host's metadata during a destination change.
    @State private var catalogDevice: String?
    @State private var refCatalog = RefCatalogState()
    @State private var refsRetry = 0
    @State private var selectedRef: String?
    @State private var checkoutKind: CheckoutKind = .local
    @State private var busy = false
    @FocusState private var focused: Bool
    /// Basis for the leading header's fixed width (SessionView's pattern —
    /// iOS 26 proposes leading toolbar items almost nothing).
    @State private var viewWidth: CGFloat = 0

    init(destination: NewSessionDestination, path: Binding<[Route]>) {
        self.destination = destination
        self._path = path
        _draft = State(initialValue: DraftStore.load(DraftStore.newSessionKey(destination)))
    }

    private var effectiveDestination: NewSessionDestination {
        if case .projectless = destination, let selectedHostId {
            return .projectless(deviceId: selectedHostId)
        }
        if case .chat = destination, let selectedHostId {
            return .chat(deviceId: selectedHostId)
        }
        return destination
    }

    private var space: Space? { effectiveDestination.space(in: model.spaces) }

    private var deviceId: String? {
        effectiveDestination.deviceId(spaces: model.spaces, devices: model.devices)
    }

    private var contextLabel: String {
        switch effectiveDestination {
        case .project: return space?.displayName ?? "Project unavailable"
        case .projectless: return "No project"
        case .chat: return "Chat"
        }
    }

    private var harnesses: [HarnessInfo] {
        catalogDevice == deviceId ? (liveHarnesses ?? []) : []
    }

    private var isChat: Bool { destination.isChat }

    /// Projectless sessions and chats both pick their host device here.
    private var isProjectlessLike: Bool {
        switch destination {
        case .projectless, .chat: return true
        case .project: return false
        }
    }

    /// The agent this draft runs on: graff in chat mode, else the picked one.
    private var runHarness: String { isChat ? ChatMode.harness : harness }

    private var scopedCatalogs: [String: [ModelInfo]] {
        catalogDevice == deviceId ? catalogs : [:]
    }

    /// A chat offers the three auto tiers and nothing else.
    private var models: [ModelInfo] {
        if isChat { return ChatMode.models(from: scopedCatalogs[ChatMode.harness] ?? []) }
        return scopedCatalogs[harness] ?? []
    }

    /// Whether this device's graff lists any of the auto tiers.
    private var chatAvailability: ChatMode.Availability {
        guard catalogDevice == deviceId else { return .pending }
        return ChatMode.availability(catalog: scopedCatalogs[ChatMode.harness] ?? [],
                                     liveHarnesses: confirmedHarnesses,
                                     liveModels: confirmedCatalogs[ChatMode.harness])
    }

    private var selectionUnavailable: Bool {
        guard catalogDevice == deviceId else { return false }
        if isChat { return chatAvailability == .unavailable }
        return HarnessCatalog.selectionUnavailable(harness: harness, modelId: selectedModel.id,
            liveHarnesses: confirmedHarnesses, liveModels: confirmedCatalogs[harness])
    }

    private var selectedModel: ModelInfo {
        if isChat {
            // Its own last pick, so a chat never changes the coding defaults.
            return ChatMode.selectedModel(storedId: storedChatModel,
                                          catalog: scopedCatalogs[ChatMode.harness] ?? [],
                                          loading: catalogsLoading)
        }
        if storedModel.isEmpty, models.isEmpty {
            return ModelInfo(id: "", label: catalogsLoading ? "Loading models…" : "Select model",
                             description: nil, reasoningLevels: [])
        }
        // Catalog hydration may add metadata, but must never replace a saved
        // model with a static default (including in the config sent by Send).
        return HarnessCatalog.resolve(modelId: storedModel.isEmpty ? nil : storedModel,
                               in: models, harness: harness)
    }

    private var reasoning: String? {
        guard !selectedModel.id.isEmpty else { return nil }
        if HarnessCatalog.resolveExisting(modelId: selectedModel.id, in: models) == nil {
            return storedReasoning.isEmpty ? nil : storedReasoning
        }
        if selectedModel.reasoningLevels.isEmpty { return nil }
        if selectedModel.reasoningLevels.contains(storedReasoning) { return storedReasoning }
        return HarnessCatalog.defaultReasoning(for: selectedModel)
    }

    private func selectedChoice(for option: ModelOptionInfo) -> ModelOptionChoiceInfo {
        HarnessCatalog.selectedChoice(for: option, selectedId: optionSelections[option.id])
    }

    /// Only non-default picks ride the run, matching the desktop picker.
    private var resolvedModelOptions: [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for option in selectedModel.options {
            let choice = selectedChoice(for: option)
            if choice.id != option.defaultChoice {
                result[option.id] = .string(choice.id)
            }
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            // Canvas — tap dismisses the keyboard, like the old app.
            ZStack {
                Theme.bg
                VStack(spacing: 24) {
                    HarnessMark()
                        .frame(width: 84, height: 84)
                        .opacity(0.22)
                    Text(isChat ? "What's on your mind?" : "What are we building?")
                        .font(Theme.sans(15))
                        .foregroundStyle(Theme.textFaint)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { focused = false }

            if let deviceId, let notice = model.hostNotice(for: deviceId) {
                hostNotice(notice, deviceId: deviceId)
            }

            if isProjectlessLike {
                Button {
                    focused = false
                    showHostPicker = true
                } label: {
                    Label(deviceId.map(model.deviceName) ?? "Select a device",
                          systemImage: "desktopcomputer")
                        .font(Theme.sans(13, weight: .medium))
                }
                .accessibilityIdentifier("session-host")
                .disabled(busy)
                .padding(.bottom, 8)
            }

            if isChat, let note = ChatMode.note(for: selectedModel.id) {
                Text(note)
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.textMuted)
                    .accessibilityIdentifier("chat-mode-note")
                    .padding(.bottom, 6)
            }

            // Where-it-runs scope row (checkout + base ref), left-aligned
            // above the composer — the composer pill keeps only the agent chip.
            if space?.gitDetected == true {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip(icon: checkoutIcon, label: checkoutLabel) {
                            focused = false
                            showCheckoutPicker = true
                        }
                        .accessibilityIdentifier("session-checkout")
                        chip(icon: .gitBranch, label: refLabel) {
                            focused = false
                            showRefPicker = true
                        }
                        .accessibilityIdentifier("session-ref")
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 8)
            }

            composer
                .padding(.bottom, 8)
        }
        .background(Theme.bg.ignoresSafeArea())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewWidth = $0 }
        .onChange(of: space?.id) { refFailure = nil }
        .navigationTitle("New session")  // feeds the back menu
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)  // the leading header owns the bar
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("New session")
                        .font(Theme.sans(13, weight: .medium))
                        .foregroundStyle(Theme.text)
                    if let deviceId {
                        Text("\(contextLabel) · \(model.deviceName(deviceId))")
                            .font(Theme.sans(10.5))
                            .foregroundStyle(Theme.textMuted.opacity(0.6))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("new-session-context")
                    } else {
                        Text(contextLabel).font(Theme.sans(10.5))
                    }
                }
                // 170: enough slack that the bar never evicts the item into
                // the "…" overflow (SessionView.headerChromeInset).
                .frame(width: max(140, viewWidth - 170), alignment: .leading)
            }
            // Bare text on the bar, not a glass capsule.
            .sharedBackgroundVisibility(.hidden)
        }
        .sheet(isPresented: $showHostPicker) {
            SessionHostPickerSheet(selectedDeviceId: deviceId) { selectedHostId = $0 }
        }
        .sheet(isPresented: $showRefPicker) {
            RefPickerSheet(refs: refs, selected: selectedRef, loading: refsLoading,
                           loadError: refCatalog.scope == refsScope ? refCatalog.error : nil,
                           onRetry: { refsRetry += 1 }) { ref in
                await pickRef(ref)
            }
        }
        .sheet(isPresented: $showCheckoutPicker) {
            CheckoutPickerSheet(kind: checkoutKind,
                                selectedRefHasWorktree: selectedRefRow?.worktreePath != nil) { kind in
                pickCheckout(kind)
            }
        }
        .task(id: "\(refsScope ?? "")|\(deviceId.map(model.deviceOnline) ?? false)|\(refsRetry)") {
            guard let space, space.gitDetected else {
                refCatalog.clear()
                selectedRef = nil
                return
            }
            if refCatalog.scope != refsScope {
                selectedRef = nil
                checkoutKind = .local
            }
            await loadRefs(for: space)
        }
        .task(id: "\(deviceId ?? "")|\(deviceId.map(model.deviceOnline) ?? false)|\(catalogRetry)") {
            guard let deviceId else {
                liveHarnesses = nil
                catalogs = [:]
                confirmedHarnesses = nil
                confirmedCatalogs = [:]
                optionSelections = [:]
                catalogDevice = nil
                catalogsLoading = false
                return
            }
            if catalogDevice != deviceId {
                liveHarnesses = DocDisk.loadHarnesses(deviceId: deviceId)
                catalogs = [:]
                confirmedHarnesses = nil
                confirmedCatalogs = [:]
                optionSelections = [:]
                catalogDevice = deviceId
                if let cached = DocDisk.loadModels(deviceId: deviceId, harness: runHarness), !cached.isEmpty {
                    catalogs[runHarness] = cached
                }
            }
            // Reconnect and explicit retry preserve rows/picks. Presence is
            // advisory: a stale offline beat must not suppress a manual retry.
            catalogsLoading = true
            let result = await model.listHarnesses(deviceId: deviceId)
            guard !Task.isCancelled else { return }
            let list = result.items
            liveHarnesses = list
            confirmedHarnesses = result.isLive ? list : nil
            if storedModel.isEmpty, !list.contains(where: { $0.id == harness }), let first = list.first {
                harness = first.id
            }
            await withTaskGroup(of: (String, DeviceCatalog<ModelInfo>).self) { group in
                for h in list {
                    if catalogs[h.id] == nil, let cached = DocDisk.loadModels(deviceId: deviceId, harness: h.id),
                       !cached.isEmpty {
                        catalogs[h.id] = cached
                    }
                    group.addTask { (h.id, await model.listModels(deviceId: deviceId, harness: h.id)) }
                }
                for await (id, catalog) in group {
                    guard !Task.isCancelled else { return }
                    catalogs[id] = catalog.items
                    confirmedCatalogs[id] = catalog.isLive ? catalog.items : nil
                }
            }
            guard !Task.isCancelled else { return }
            catalogsLoading = false
        }
        .sheet(isPresented: $showPicker) {
            if isChat {
                // A chat offers the three auto tiers and nothing else.
                ModelPickerSheet(harness: .constant(ChatMode.harness), modelId: Binding(
                    get: { selectedModel.id },
                    set: { storedChatModel = $0 }
                ), reasoning: .constant(nil), lockedHarness: true,
                   catalogs: models.isEmpty && chatAvailability == .pending ? [:] : [ChatMode.harness: models],
                   catalogsLoading: chatAvailability == .pending,
                   onRetry: { catalogRetry += 1 })
            } else {
                ModelPickerSheet(harness: $harness, modelId: Binding(
                    get: { selectedModel.id },
                    set: { storedModel = $0 }
                ), reasoning: Binding(
                    get: { reasoning },
                    set: { storedReasoning = $0 ?? "" }
                ), harnesses: harnesses, catalogs: scopedCatalogs,
                   catalogsLoading: catalogsLoading || catalogDevice != deviceId,
                   onRetry: { catalogRetry += 1 })
            }
        }
        .sheet(isPresented: $showTraitPicker) {
            TraitPickerSheet(reasoning: Binding(
                get: { reasoning },
                set: { storedReasoning = $0 ?? "" }
            ), levels: selectedModel.reasoningLevels)
        }
        .sheet(item: $showOptionPicker) { option in
            ModelOptionPickerSheet(option: option, choiceId: Binding(
                get: { selectedChoice(for: option).id },
                set: { optionSelections[option.id] = $0 }
            ))
        }
        .themedPhotosPicker(isPresented: $showPhotoPicker, selection: $pickerItems)
        .onChange(of: draft) { _, new in
            DraftStore.save(new, for: DraftStore.newSessionKey(destination))
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            stage(items)
        }
        .onAppear {
            focused = true
            if model.launchAutosend {
                model.launchAutosend = false
                draft = "Sketch the plan for porting the diff pane."
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    send()
                }
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 6) {
            if selectionUnavailable {
                Text(isChat ? ChatMode.unavailableNote
                     : "Selected agent or model is unavailable on this device. Choose another model.")
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 24)
                    .accessibilityIdentifier("model-selection-unavailable")
            }
            if let attachError {
                Text(attachError)
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.danger)
                    .lineLimit(2)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let refFailure {
                Text(refFailure.summary)
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.danger)
                    .lineLimit(2)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("session-ref-error")
            }
            ComposerShell(
                draft: $draft,
                placeholder: isChat ? "Ask anything…" : "Do anything…",
                sendEnabled: deviceId != nil && !selectedModel.id.isEmpty && !selectionUnavailable
                    && (refsScope == nil || refCatalog.scope == refsScope),
                showStop: false,
                busy: busy,
                alwaysExpanded: true,
                onSend: send,
                attachments: attachments,
                onAttach: { showPhotoPicker = true },
                onPasteImages: { images in
                    let (staged, failed) = StagedAttachment.stage(images: images)
                    attachments.append(contentsOf: staged)
                    attachError = StagedAttachment.failureMessage(failed)
                },
                onRemoveAttachment: { id in attachments.removeAll { $0.id == id } }
            ) {
                // Model + trait chips, split like the desktop's footer pickers
                // (they ride right of the shell's attach button).
                ComposerChip(label: selectedModel.label, badgeHarness: runHarness) {
                    focused = false
                    showPicker = true
                }
                if let reasoning {
                    ComposerChip(label: HarnessCatalog.reasoningLabel(reasoning)) {
                        focused = false
                        showTraitPicker = true
                    }
                }
                ForEach(selectedModel.options) { option in
                    ComposerChip(label: selectedChoice(for: option).label) {
                        focused = false
                        showOptionPicker = option
                    }
                }
            }
        }
    }

    /// Load picked photos into staged attachments (ComposerView.stage's twin —
    /// the upload happens on send, once the chat and its store exist).
    private func stage(_ items: [PhotosPickerItem]) {
        Task { @MainActor in
            var failed = 0
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let staged = StagedAttachment.stage(data: data) else {
                    failed += 1
                    continue
                }
                attachments.append(staged)
            }
            pickerItems = []
            attachError = failed > 0
                ? (failed == 1 ? "One image couldn't be attached (unsupported or over 24 MB)."
                               : "\(failed) images couldn't be attached (unsupported or over 24 MB).")
                : nil
        }
    }

    private func chip(icon: LineIcon, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                LineIconView(icon, size: 13, color: Theme.textMuted)
                Text(label)
                    .font(Theme.sans(13, weight: .medium))
                    .foregroundStyle(Theme.text.opacity(0.9))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(ink(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(hairline(0.08), lineWidth: 1))
        }
        .buttonStyle(ChipPressButtonStyle())
    }

    // MARK: Checkout model (pickers.rs port)

    private var refsScope: String? {
        guard let space, space.gitDetected else { return nil }
        return "\(space.id)/\(space.deviceId)/\(space.path)"
    }

    private var refs: [RepoRef] {
        refCatalog.scope == refsScope ? refCatalog.items : []
    }

    private var refsLoading: Bool {
        refsScope != nil && (refCatalog.scope != refsScope || refCatalog.loading)
    }

    private func loadRefs(for space: Space) async {
        let scope = "\(space.id)/\(space.deviceId)/\(space.path)"
        let request = refCatalog.begin(scope: scope)
        let loaded = await model.listRefs(space: space)
        guard !Task.isCancelled, refsScope == scope else { return }
        guard refCatalog.finish(request, items: loaded,
            failure: "Couldn't load refs from the device. Check its connection and try again.") else { return }
        if selectedRef == nil, let loaded {
            // Only a reported current ref can name the current checkout.
            selectedRef = loaded.first(where: \.current)?.name
        }
    }

    private var selectedRefRow: RepoRef? {
        refs.first { $0.name == selectedRef }
    }

    /// checkout_label: New worktree / Current worktree / Current checkout.
    private var checkoutLabel: String {
        switch checkoutKind {
        case .newWorktree: return "New worktree"
        case .local: return selectedRefRow?.worktreePath != nil ? "Current worktree" : "Current checkout"
        }
    }

    private var checkoutIcon: LineIcon {
        checkoutKind == .local && selectedRefRow?.worktreePath == nil ? .folder : .folderWithFiles
    }

    /// ref_label: "From <ref>" only when a NEW worktree will be created off it.
    private var refLabel: String {
        guard refCatalog.scope == refsScope, let name = selectedRef else { return "Select ref" }
        return checkoutKind == .newWorktree ? "From \(name)" : name
    }

    /// pick_ref (draft mode): a worktree'd ref flips to "Current worktree";
    /// base picks just record; a plain non-current ref in Local mode CHECKS
    /// OUT the space folder (it must never silently flip the mode).
    private func pickRef(_ row: RepoRef) async -> String? {
        refFailure = nil
        if row.worktreePath != nil {
            selectedRef = row.name
            checkoutKind = .local
            return nil
        }
        if checkoutKind == .newWorktree || row.current {
            selectedRef = row.name
            return nil
        }
        guard let space else { return nil }
        let scope = refsScope
        let kept = selectedRef
        let error = await model.switchSpaceRef(space: space, refName: row.name)
        guard !Task.isCancelled, refsScope == scope else {
            return "The destination changed. Choose the ref again."
        }
        // Outlives the sheet: closing it mid-checkout must not lose the reason.
        refFailure = error.map { RefCheckoutFailure(ref: row.name, reason: $0, kept: kept) }
        if error == nil {
            selectedRef = row.name
            await loadRefs(for: space)
        }
        return error
    }

    /// pick_checkout: dropping back to Local with a plain non-current ref
    /// picked drops the pick — the current branch takes over.
    private func pickCheckout(_ kind: CheckoutKind) {
        if kind == .local, checkoutKind == .newWorktree,
           let row = selectedRefRow, row.worktreePath == nil, !row.current {
            selectedRef = refs.first(where: \.current)?.name
        }
        checkoutKind = kind
    }

    private var canSend: Bool {
        guard !busy, deviceId != nil, !selectedModel.id.isEmpty, !selectionUnavailable,
              refsScope == nil || refCatalog.scope == refsScope else { return false }
        return !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachments.isEmpty
    }

    /// Only says what is true: a dead sign-in, a phone that is not connected, or a host that is positively
    /// gone. A host that is merely unconfirmed gets no warning (see AppModel.hostNotice).
    @ViewBuilder
    private func hostNotice(_ notice: AppModel.HostNotice, deviceId: String) -> some View {
        let name = model.deviceName(deviceId)
        switch notice {
        case .signedOut:
            Button { model.signInAgain() } label: {
                noticeText("You're signed out — tap to sign in again.")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("new-session-signed-out")
        case .reconnecting:
            noticeText("Reconnecting — \(name)'s status will show once you're connected.")
        case .offline:
            noticeText("\(name) is offline — the run will start when it reconnects.")
        }
    }

    private func noticeText(_ message: String) -> some View {
        Text(message)
            .font(Theme.sans(12))
            .foregroundStyle(Theme.warning.opacity(0.9))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Theme.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
    }

    /// Mint the chat per the checkout plan, queue the first run, swap to the
    /// live session. The atomic ordering (PRs #159/#170): anything that can
    /// FAIL stages before anything is created — a legacy attachment upload
    /// aborts with no chat row anywhere — and nothing left in the pipeline
    /// blocks on a relay RPC. A New-worktree plan rides the queued Run as a
    /// WorktreeSpec the HOST materializes at drain time; the old
    /// CreateWorktree-before-send was the one new-chat path that could hang
    /// forever on a zombie link (the 2026-08-18 "Sending…" incident).
    private func send() {
        guard let deviceId, canSend else { return }
        let space = space
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        busy = true
        let config = ChatConfig(harness: runHarness, model: selectedModel.id,
                                reasoning: reasoning, modelOptions: resolvedModelOptions,
                                sandbox: "workspace-write", chatMode: isChat ? true : nil)
        Task { @MainActor in
            var cwd: String?
            let branch = space == nil ? nil : selectedRef
            var worktree: WorktreeSpec?
            if let space {
                switch checkoutKind {
                case .newWorktree:
                    // The host materializes the worktree at drain time, so
                    // an offline send never blocks on a relay RPC.
                    worktree = WorktreeSpec(repoPath: space.path, base: selectedRef ?? "HEAD")
                    cwd = space.path
                case .local:
                    if let reused = selectedRefRow?.worktreePath {
                        cwd = reused
                    }
                }
            }

            let staged = attachments
            let queued = model.hostSupportsQueuedAttachmentsOn(deviceId: deviceId)

            // Legacy hosts (< 0.2.12) stage attachments FIRST — before the
            // chat row or store exist — so an upload failure aborts with
            // nothing created (no stranded empty chat in the sidebar).
            var legacyPaths: [String] = []
            if !staged.isEmpty, !queued, model.demo == nil {
                guard let workspace = model.workspace else {
                    busy = false
                    return
                }
                do {
                    for att in staged {
                        let uploadId = UUID().uuidString.lowercased()
                        let uploaded = try await workspace.uploadAttachment(
                            deviceId: deviceId, name: att.name, data: att.data,
                            uploadId: uploadId)
                        AttachmentImageCache.shared.seed(deviceId: deviceId, path: uploaded,
                                                         name: att.name, data: att.data)
                        legacyPaths.append(uploaded)
                    }
                } catch {
                    attachError = "Attachment upload failed — \(error.localizedDescription)"
                    busy = false
                    return
                }
            }

            let createdId: String?
            if let space {
                createdId = model.createChat(space: space, config: config, branch: branch, cwd: cwd)
            } else {
                createdId = model.createProjectlessChat(deviceId: deviceId, config: config)
            }
            guard let chatId = createdId,
                  let chat = model.chat(id: chatId),
                  let store = model.sessionStore(for: chat) else {
                busy = false
                return
            }
            if queued, !staged.isEmpty {
                // Queued flow: pending:// refs make the whole send a durable
                // local write; the escort pushes bytes afterwards.
                let transfers = staged.map {
                    AttachmentTransfer(uploadId: UUID().uuidString.lowercased(),
                                       name: $0.name, data: $0.data)
                }
                for (transfer, att) in zip(transfers, staged) {
                    AttachmentImageCache.shared.seed(
                        deviceId: chat.deviceId,
                        path: UploadStash.pendingRef(uploadId: transfer.uploadId,
                                                     name: transfer.name),
                        name: att.name, data: att.data)
                }
                store.sendWithTransfers(prompt: prompt, chat: chat, live: false,
                                        transfers: transfers, worktree: worktree)
            } else {
                store.sendRun(prompt: legacyPaths.isEmpty ? prompt
                                  : withAttachments(text: prompt, paths: legacyPaths),
                              chat: chat, attachments: legacyPaths, worktree: worktree)
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            draft = ""
            attachments = []
            busy = false
            // Replace the canvas with the live session (in-place swap, no
            // back-through-canvas).
            if path.last == .newSession(destination) {
                path.removeLast()
            }
            path.append(.chat(chatId))
        }
    }
}

// MARK: - Composer chip

/// The composer's picker trigger chip: optional brand mark, label, chevron —
/// one per picker, split like the desktop's footer (model | traits).
struct ComposerChip: View {
    let label: String
    var badgeHarness: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let badgeHarness {
                    HarnessBadge(harness: badgeHarness, size: 15)
                }
                Text(label)
                    .font(Theme.sans(13, weight: .medium))
                    .foregroundStyle(Theme.text.opacity(0.9))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 13)
            .frame(height: 40)
            .background(ink(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(hairline(0.08), lineWidth: 1))
        }
        .buttonStyle(ChipPressButtonStyle())
    }
}

// MARK: - Model picker sheet

/// Detent bottom sheet in the t3 settings-sheet layout: one scrolling list of
/// models sectioned per harness (collapsible uppercase provider headers with
/// the brand mark — picking a model picks its harness), the selected row a
/// filled high-contrast pill with a trailing checkmark. Effort lives in its
/// own TraitPickerSheet, split like the desktop's footer pickers. Harness
/// sections collapse to one once a chat exists — harness is locked mid-chat.
struct ModelPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var harness: String
    @Binding var modelId: String
    @Binding var reasoning: String?
    /// True when reconfiguring a live chat: the harness can't change mid-chat.
    var lockedHarness = false
    /// Only host-discovered or per-host cached agents are offered.
    var harnesses: [HarnessInfo] = []
    /// Live or cached metadata; a missing entry is not a static default.
    var catalogs: [String: [ModelInfo]] = [:]
    var catalogsLoading = false
    var onRetry: (() -> Void)?

    private func models(for harness: String) -> [ModelInfo] {
        catalogs[harness] ?? []
    }

    private var sections: [HarnessInfo] {
        if lockedHarness {
            return [HarnessInfo(id: harness, label: HarnessCatalog.label(for: harness))]
        }
        return harnesses
    }

    /// Accordion state: which harness sections show their models. Seeded with
    /// the current harness — with several agents enabled a flat list of every
    /// catalog is unmanageable (t3's collapsible provider folds).
    @State private var openSections: Set<String> = []
    @State private var query = ""
    /// The selection this opening compares against for the top-right control.
    @State private var baseline: SelectionBaseline<ModelSelection>

    init(harness: Binding<String>, modelId: Binding<String>, reasoning: Binding<String?>,
         lockedHarness: Bool = false, harnesses: [HarnessInfo] = [],
         catalogs: [String: [ModelInfo]] = [:], catalogsLoading: Bool = false,
         onRetry: (() -> Void)? = nil) {
        self._harness = harness
        self._modelId = modelId
        self._reasoning = reasoning
        self.lockedHarness = lockedHarness
        self.harnesses = harnesses
        self.catalogs = catalogs
        self.catalogsLoading = catalogsLoading
        self.onRetry = onRetry
        self._baseline = State(initialValue: SelectionBaseline(
            ModelSelection(harness: harness.wrappedValue, modelId: modelId.wrappedValue)))
    }

    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Models in `harness` matching the search (all of them when not searching).
    private func shown(for harness: String) -> [ModelInfo] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return models(for: harness) }
        return models(for: harness).filter { m in
            [m.label, m.id, m.description ?? ""].contains { $0.localizedCaseInsensitiveContains(needle) }
        }
    }

    /// While searching, only sections with a match, each open.
    private var shownSections: [HarnessInfo] {
        searching ? sections.filter {
            !shown(for: $0.id).isEmpty || (catalogsLoading && catalogs[$0.id] == nil)
        } : sections
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 4) {
                        SheetLabel("Model")
                        if let onRetry, !catalogsLoading {
                            Button("Refresh models", action: onRetry)
                                .font(Theme.sans(13))
                                .accessibilityIdentifier("model-picker-retry")
                        }
                        if !modelId.isEmpty, selectedModel == nil {
                            Text("Current selection: \(modelId)")
                                .font(Theme.sans(13))
                                .foregroundStyle(Theme.textMuted)
                                .accessibilityIdentifier("model-picker-current")
                        }
                        if sections.isEmpty {
                            if catalogsLoading {
                                ProgressView("Loading agents…")
                                    .accessibilityIdentifier("model-picker-loading")
                            } else {
                                Text("No agents available from this device. Check its connection and enabled agents.")
                                    .font(Theme.sans(13))
                                    .foregroundStyle(Theme.textMuted)
                                    .accessibilityIdentifier("model-picker-unavailable")
                            }
                        }
                        if searching, shownSections.isEmpty, !catalogsLoading, !sections.isEmpty {
                            Text("No models match \u{201C}\(query)\u{201D}")
                                .font(Theme.sans(13))
                                .foregroundStyle(Theme.textFaint)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 28)
                        }
                        ForEach(shownSections) { h in
                            if sections.count > 1 {
                                sectionHeader(h)
                            }
                            if sections.count == 1 || searching || openSections.contains(h.id) {
                                if catalogs[h.id] == nil, catalogsLoading {
                                    ProgressView("Loading models…")
                                        .accessibilityIdentifier("model-picker-loading")
                                } else if models(for: h.id).isEmpty {
                                    Text("No models available from this device. Check its connection and model settings.")
                                        .font(Theme.sans(13))
                                        .foregroundStyle(Theme.textMuted)
                                        .accessibilityIdentifier("model-picker-unavailable")
                                }
                                ForEach(shown(for: h.id)) { m in
                                    PickRow(title: m.label,
                                            subtitle: m.description,
                                            selected: harness == h.id && m.id == selectedModel?.id) {
                                        select(harness: h.id, model: m)
                                    }
                                }
                            }
                        }
                    }
                    .onAppear { openSections = [harness] }
                    .onChange(of: harness) { _, value in openSections.insert(value) }
                }
                .padding(20)
                .padding(.bottom, 12)
            }
            .background(SheetStyle.panel)
            .navigationTitle("Select model")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search models")
            .toolbar {
                SheetConfirmItem(changed: selectionChanged,
                                 identifier: "model-picker-confirm") { dismiss() }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .harnessAppearance()
        .onChange(of: currentSelection) { _, value in baseline.hydrated(to: value) }
    }

    private var currentSelection: ModelSelection {
        ModelSelection(harness: harness, modelId: modelId)
    }

    private var selectionChanged: Bool {
        baseline.changed(to: currentSelection) {
            HarnessCatalog.sameRow($0, $1, catalogs: catalogs)
        }
    }

    private var selectedModel: ModelInfo? {
        HarnessCatalog.resolveExisting(modelId: modelId, in: models(for: harness))
    }

    /// t3's collapsible ProviderHeader: brand mark + tracked-out uppercase
    /// provider name, trailing model count + chevron; tapping folds the section.
    private func sectionHeader(_ h: HarnessInfo) -> some View {
        let open = openSections.contains(h.id)
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(Motion.collapse) {
                if open { openSections.remove(h.id) } else { openSections.insert(h.id) }
            }
        } label: {
            HStack(spacing: 7) {
                HarnessBadge(harness: h.id, size: 13)
                Text(h.label.uppercased())
                    .font(Theme.sans(10.5, weight: .medium))
                    .kerning(1.2)
                    .foregroundStyle(Theme.textMuted.opacity(0.7))
                Spacer(minLength: 8)
                if !open {
                    Text("\(models(for: h.id).count)")
                        .font(Theme.sans(10.5))
                        .foregroundStyle(Theme.textFaint)
                }
                Image(systemName: open ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 4)
            .padding(.top, 12)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func select(harness harnessId: String, model m: ModelInfo) {
        UISelectionFeedbackGenerator().selectionChanged()
        baseline.picked()
        if harness != harnessId {
            harness = harnessId
        }
        modelId = m.id
        if let current = reasoning, m.reasoningLevels.contains(current) {
            return
        }
        reasoning = HarnessCatalog.defaultReasoning(for: m)
    }

}

// MARK: - Trait (effort) picker sheet

/// The effort ladder in its own detent sheet — the composer's second picker
/// chip, split from the model list like the desktop's Traits dropdown.
struct TraitPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var reasoning: String?
    let levels: [String]
    @State private var initialReasoning: String?

    init(reasoning: Binding<String?>, levels: [String]) {
        self._reasoning = reasoning
        self.levels = levels
        self._initialReasoning = State(initialValue: reasoning.wrappedValue)
    }

    private var selectionChanged: Bool { reasoning != initialReasoning }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    SheetLabel("Effort")
                    ForEach(levels, id: \.self) { level in
                        PickRow(title: HarnessCatalog.reasoningLabel(level),
                                subtitle: Self.effortHint(level),
                                selected: reasoning == level) {
                            UISelectionFeedbackGenerator().selectionChanged()
                            reasoning = level
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 12)
            }
            .background(SheetStyle.panel)
            .navigationTitle("Reasoning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                SheetConfirmItem(changed: selectionChanged,
                                 identifier: "reasoning-picker-confirm") { dismiss() }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .harnessAppearance()
    }

    /// One-line hints for the ladder (the special modes deserve explanation).
    static func effortHint(_ level: String) -> String? {
        switch level {
        case "minimal": return "Quickest, lightest touch"
        case "low": return "Fastest responses"
        case "medium": return "Balanced speed and depth"
        case "high": return "Thorough reasoning"
        case "xhigh": return "Extended reasoning"
        case "max": return "Maximum reasoning budget"
        case "ultra": return "Highest Codex tier"
        case "ultracode": return "X-High plus the ultracode setting"
        case "ultrathink": return "Deep-thinking prompt mode"
        default: return nil
        }
    }
}

// MARK: - Model option picker sheet

/// Generic harness option picker. Codex uses it for Standard/Fast; decoding
/// the wire shape keeps iOS ready for further server-advertised choices.
struct ModelOptionPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let option: ModelOptionInfo
    @Binding var choiceId: String

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    SheetLabel(option.label)
                    ForEach(option.choices) { choice in
                        PickRow(title: choice.label,
                                subtitle: hint(for: choice),
                                selected: choiceId == choice.id) {
                            UISelectionFeedbackGenerator().selectionChanged()
                            choiceId = choice.id
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 12)
            }
            .background(SheetStyle.panel)
            .navigationTitle(option.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .harnessAppearance()
    }

    private func hint(for choice: ModelOptionChoiceInfo) -> String? {
        guard option.id == "serviceTier" else { return nil }
        switch choice.id {
        case "default": return "Standard response speed"
        case "fast": return "Faster responses with increased usage"
        default: return nil
        }
    }
}

// MARK: - Shared picker row

/// t3's ModelRow — the ONE row style every picker sheet uses (model, trait,
/// ref, checkout): the selected row is a filled high-contrast pill with a
/// trailing checkmark; unselected rows sit almost flat on the sheet. Optional
/// leading line icon and a busy spinner for rows whose pick runs async (git
/// checkouts).
struct PickRow: View {
    let title: String
    var subtitle: String?
    var icon: LineIcon?
    var busy = false
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon {
                    LineIconView(icon, size: 15,
                                 color: selected ? Theme.bg : Theme.textMuted)
                        .frame(width: 20)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.sans(15, weight: .medium))
                        .foregroundStyle(selected ? Theme.bg : Theme.text)
                    if let subtitle {
                        Text(subtitle)
                            .font(Theme.sans(12))
                            .foregroundStyle(selected ? Theme.bg.opacity(0.65) : Theme.textMuted)
                    }
                }
                Spacer(minLength: 8)
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(selected ? Theme.bg : Theme.textMuted)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.bg)
                        .opacity(selected ? 1 : 0)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AnyShapeStyle(Theme.text) : AnyShapeStyle(ink(0.03)),
                        in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(SheetRowButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Picker sheet confirmation

/// A picker sheet's top-right control: an X (Close) while the selection
/// matches the one the sheet opened with, and a checkmark (Done) once it
/// differs. The checkmark uses the selected PickRow's colors — `Theme.text`
/// circle, `Theme.bg` tick — drawn as an original-color palette symbol so
/// toolbar tinting can't shift them (#407, #416).
struct SheetConfirmItem: ToolbarContent {
    let changed: Bool
    let identifier: String
    let action: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button(action: action) {
                if changed {
                    Image(systemName: "checkmark.circle.fill")
                        .renderingMode(.original)
                        .resizable()
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Theme.bg, Theme.text)
                        .frame(width: 44, height: 44)
                } else {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(changed ? "Done" : "Close")
            .accessibilityIdentifier(identifier)
        }
        .sharedBackgroundVisibility(changed ? .hidden : .automatic)
    }
}

// MARK: - Ref picker sheet

/// Base-ref selector (the desktop footer's branch popover): branch rows with
/// current-checkout / worktree markers. Picks that require a git checkout run
/// inline — a spinner on the row, git's error pinned above the list on
/// failure (dirty tree, held ref) with the old selection kept, success
/// dismisses.
struct RefPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let refs: [RepoRef]
    let selected: String?
    var loading = false
    var loadError: String?
    var onRetry: () -> Void = {}
    /// Returns an error message to keep the sheet open, or nil to close.
    let onPick: (RepoRef) async -> String?

    @State private var switching: String?
    @State private var failure: RefCheckoutFailure?
    @State private var query = ""

    private var shownRefs: [RepoRef] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return refs }
        return refs.filter { $0.name.localizedCaseInsensitiveContains(needle) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    SheetLabel("Ref")
                    if loading {
                        ProgressView(refs.isEmpty ? "Loading refs from the device…" : "Refreshing refs…")
                            .accessibilityIdentifier("refs-loading")
                    }
                    if let loadError {
                        Text(loadError)
                            .font(Theme.sans(13))
                            .foregroundStyle(Theme.danger)
                            .accessibilityIdentifier("refs-load-error")
                        Button("Retry", action: onRetry)
                            .disabled(loading)
                            .accessibilityIdentifier("refs-retry")
                    }
                    if refs.isEmpty, !loading, loadError == nil {
                        Text("No refs available. This repository may not have a commit yet.")
                            .font(Theme.sans(13))
                            .foregroundStyle(Theme.textFaint)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                            .accessibilityIdentifier("refs-empty")
                        Button("Retry", action: onRetry)
                            .accessibilityIdentifier("refs-retry")
                    } else if !refs.isEmpty, shownRefs.isEmpty {
                        Text("No refs match \u{201C}\(query)\u{201D}")
                            .font(Theme.sans(13))
                            .foregroundStyle(Theme.textFaint)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                    } else {
                        ForEach(shownRefs, id: \.name) { ref in
                            row(ref)
                        }
                    }
                }
                .padding(20)
            }
            // Pinned, not after the rows: a long list scrolled the old inline
            // error out of the medium detent, so a refusal looked like a stall.
            .safeAreaInset(edge: .top, spacing: 0) {
                if let failure {
                    failureBanner(failure)
                }
            }
            .background(SheetStyle.panel)
            .navigationTitle("Select ref")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search branches and tags")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .harnessAppearance()
    }

    private func row(_ ref: RepoRef) -> some View {
        PickRow(title: ref.name,
                subtitle: subtitle(for: ref),
                busy: switching == ref.name,
                selected: ref.name == selected) {
            guard switching == nil else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            failure = nil
            switching = ref.name
            let kept = selected
            Task { @MainActor in
                let result = await onPick(ref)
                switching = nil
                if let result {
                    let refused = RefCheckoutFailure(ref: ref.name, reason: result, kept: kept)
                    failure = refused
                    AccessibilityNotification.Announcement(refused.announcement).post()
                } else {
                    dismiss()
                }
            }
        }
    }

    private func failureBanner(_ failure: RefCheckoutFailure) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.danger)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(failure.title)
                    .font(Theme.sans(13.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Text(failure.reason)
                    .font(Theme.sans(12.5))
                    .foregroundStyle(Theme.danger)
                    .lineLimit(6)
                    .textSelection(.enabled)
                Text(failure.keptNote)
                    .font(Theme.sans(12))
                    .foregroundStyle(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ref-checkout-error")
            Button {
                self.failure = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.danger.opacity(0.25), lineWidth: 1))
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .background(SheetStyle.panel)
    }

    private func subtitle(for ref: RepoRef) -> String? {
        if ref.current { return "Current checkout" }
        if ref.worktreePath != nil { return "Checked out in a worktree" }
        return nil
    }
}

// MARK: - Checkout picker sheet

/// Where the session runs (the desktop's checkout popover): the space's
/// folder as-is (or the picked ref's existing worktree), or a fresh isolated
/// worktree created off the base ref on send.
struct CheckoutPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let kind: CheckoutKind
    let selectedRefHasWorktree: Bool
    let onPick: (CheckoutKind) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    SheetLabel("Checkout")
                    row(.local,
                        title: selectedRefHasWorktree ? "Current worktree" : "Current checkout",
                        subtitle: selectedRefHasWorktree
                            ? "Reuse the picked ref's existing worktree"
                            : "Run in the space's folder as-is")
                    row(.newWorktree, title: "New worktree",
                        subtitle: "A fresh isolated worktree created off the picked base ref")
                }
                .padding(20)
            }
            .background(SheetStyle.panel)
            .navigationTitle("Checkout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .harnessAppearance()
    }

    private func row(_ rowKind: CheckoutKind, title: String, subtitle: String) -> some View {
        PickRow(title: title, subtitle: subtitle, selected: rowKind == kind) {
            UISelectionFeedbackGenerator().selectionChanged()
            onPick(rowKind)
            dismiss()
        }
    }
}
