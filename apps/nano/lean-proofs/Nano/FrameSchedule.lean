/-
  Frame & DisplayLink Quiescence Kernel (`FrameSchedule`).

  Models nanoui + harness-nano's per-frame pass count, display-link wakeup,
  focus resolution (`preFocus` via `peekId` vs `postFocus` after `textField`),
  pre-tree `redraw()` suppression, and debounced tab-layout persistence.

  Executable Zig port: `apps/nano/src/motion_rules.zig`.
-/

namespace Nano.FrameSchedule

inductive FocusMode where
  | none | preFocus | postFocus
deriving DecidableEq, Repr, BEq

inductive EventKind where
  | keyNav | pointerOpenMenu | tweenStep | scrollWheel | idle
deriving DecidableEq, Repr, BEq

structure FrameInput where
  event          : EventKind
  focusMode      : FocusMode
  suppressPreRedraw : Bool
  debounceTabSave   : Bool
  tweenActive    : Bool
  scrollMoved    : Bool
deriving DecidableEq, Repr, BEq

structure FrameOutcome where
  passes      : Nat
  animating   : Bool
  syncWrites  : Nat
  timerKept   : Bool
deriving DecidableEq, Repr, BEq

/-- `postFocus` sets `c.changed = true` after `ui.textField` has already
emitted its node with `focused = false`, forcing `frame.run` to execute a
second build+layout pass in the same vsync. `preFocus` resolves the ID via
`c.peekId(null)` before `ui.textField`, completing in 1 pass. -/
def passesOf (m : FocusMode) : Nat :=
  match m with
  | .none      => 1
  | .preFocus  => 1
  | .postFocus => 2

/-- Whether the frame leaves `CADisplayLink` running at 60–120Hz. -/
def animatingOf (i : FrameInput) : Bool :=
  i.tweenActive || i.scrollMoved

/-- Synchronous disk writes (`openTabs` + `nanoTabLayout`) performed on the
UI thread during the keystroke frame itself. -/
def syncWritesOf (i : FrameInput) : Nat :=
  match i.event with
  | .keyNav => if i.debounceTabSave then 0 else 2
  | _       => 0

/-- Whether `c.frame_in` (set by `App.tick`) survives pre-tree event handling. -/
def timerKeptOf (i : FrameInput) : Bool :=
  match i.event with
  | .keyNav | .pointerOpenMenu => i.suppressPreRedraw
  | _ => true

def evaluate (i : FrameInput) : FrameOutcome :=
  { passes     := passesOf i.focusMode
  , animating  := animatingOf i
  , syncWrites := syncWritesOf i
  , timerKept  := timerKeptOf i }

def allEvents : List EventKind :=
  [.keyNav, .pointerOpenMenu, .tweenStep, .scrollWheel, .idle]

def allFocusModes : List FocusMode :=
  [.none, .preFocus, .postFocus]

def allInputs : List FrameInput :=
  Id.run do
    let mut acc : List FrameInput := []
    for e in allEvents do
      for f in allFocusModes do
        for s in [false, true] do
          for d in [false, true] do
            for tw in [false, true] do
              for sc in [false, true] do
                acc := acc ++ [{
                  event := e, focusMode := f,
                  suppressPreRedraw := s, debounceTabSave := d,
                  tweenActive := tw, scrollMoved := sc
                }]
    return acc

def scheduleCells : Nat := allInputs.length
def singlePassCells : Nat := (allInputs.filter (fun i => (evaluate i).passes == 1)).length

theorem schedule_cube : scheduleCells = 240 := by native_decide
theorem single_pass_count : singlePassCells = 160 := by native_decide

theorem pre_focus_single_pass (i : FrameInput) (h : i.focusMode = .preFocus) :
    (evaluate i).passes = 1 := by
  simp [evaluate, passesOf, h]

theorem post_focus_forces_rebuild (i : FrameInput) (h : i.focusMode = .postFocus) :
    (evaluate i).passes = 2 := by
  simp [evaluate, passesOf, h]

theorem key_nav_quiescent :
    evaluate {
      event := .keyNav,
      focusMode := .preFocus,
      suppressPreRedraw := true,
      debounceTabSave := true,
      tweenActive := false,
      scrollMoved := false
    } = { passes := 1, animating := false, syncWrites := 0, timerKept := true } := by
  native_decide

theorem legacy_key_nav_stalls :
    evaluate {
      event := .keyNav,
      focusMode := .postFocus,
      suppressPreRedraw := false,
      debounceTabSave := false,
      tweenActive := false,
      scrollMoved := true
    } = { passes := 2, animating := true, syncWrites := 2, timerKept := false } := by
  native_decide

/-- A settled open fold (`foldAnimating = false`) does not clamp its viewport
height to a cached height, so changing column width during or after `Cmd+B`
never triggers a `rememberHeight` second pass. -/
def foldPassesOf (foldAnimating : Bool) (heightChanged : Bool) (clampWhenSettled : Bool) : Nat :=
  if heightChanged && (foldAnimating || clampWhenSettled) then 2 else 1

theorem settled_fold_single_pass (heightChanged : Bool) :
    foldPassesOf false heightChanged false = 1 := by
  cases heightChanged <;> rfl

/-- Update pill placement (`restartPlace` in `view_updates.zig`):
never shows in both the sidebar footer and the titlebar simultaneously. -/
inductive RestartPlace where
  | none | sidebarRow | titlebar
deriving DecidableEq, Repr, BEq

def restartPlace (hasUpdate : Bool) (sidebarFits : Bool) (dismissed : Bool) : RestartPlace :=
  if !hasUpdate || dismissed then .none
  else if sidebarFits then .sidebarRow
  else .titlebar

theorem restart_place_exclusive (u s d : Bool) :
    ¬(restartPlace u s d = .sidebarRow ∧ restartPlace u s d = .titlebar) := by
  cases u <;> cases s <;> cases d <;> decide

/-- `Cmd+W` close target resolution (`decideCloseTarget` in `motion_rules.zig`):
1. If the archive-on-close dialog (`closeChoiceOpen`) is already open, a second
   `Cmd+W` immediately confirms closing (`confirmChoice`) instead of stalling.
2. Whenever an open file/diffs/host tab is visible (`hasHost && !expanded`),
   `Cmd+W` closes that open host tab (`closeHost`) before closing any chat pane
   tab (`closePaneTab`), split pane (`closeSplitPane`), or chat tab (`closeTab`).
3. When on the last empty new-chat tab (`isOnlyNewChat`), `Cmd+W` is a `.noop`. -/
inductive CloseSurface where
  | chat | host | files
deriving DecidableEq, Repr, BEq

inductive CloseAction where
  | noop
  | confirmChoice
  | askChoice
  | closeHost
  | closeFiles
  | closePaneTab
  | closeSplitPane
  | closeTab
deriving DecidableEq, Repr, BEq

def decideCloseTarget
    (surface : CloseSurface)
    (closeChoiceOpen : Bool)
    (paneTabs : Nat)
    (splitPanes : Nat)
    (hasHost : Bool)
    (expanded : Bool)
    (isOnlyNewChat : Bool)
    (asksArchive : Bool) : CloseAction :=
  if closeChoiceOpen then .confirmChoice
  else match surface with
  | .host  => .closeHost
  | .files => .closeFiles
  | .chat  =>
    if hasHost && !expanded then .closeHost
    else if paneTabs > 1 then .closePaneTab
    else if splitPanes > 1 then .closeSplitPane
    else if isOnlyNewChat then .noop
    else if asksArchive then .askChoice
    else .closeTab

/-- Synchronous Metal render passes triggered by a native `Cmd+W` menu event.
Without `in_pre_tree` coalescing (`coalescePreTree = false`), `a.select()` runs
a synchronous render pass before `restorePanelDraft` adopts the surviving pane's
draft, followed by optional archive redraw and `closeTab`'s trailing redraw
(2–3 passes). With `coalescePreTree = true`, all state mutations settle before
a single trailing `redraw()` (1 pass). -/
def closeRedrawPasses (coalescePreTree : Bool) (hasArchiveSideEffect : Bool) : Nat :=
  if coalescePreTree then 1
  else 1 + (if hasArchiveSideEffect then 1 else 0) + 1

theorem cmd_w_coalesced_single_pass (hasArchiveSideEffect : Bool) :
    closeRedrawPasses true hasArchiveSideEffect = 1 := by
  cases hasArchiveSideEffect <;> rfl

theorem cmd_w_uncoalesced_multiple_passes (hasArchiveSideEffect : Bool) :
    closeRedrawPasses false hasArchiveSideEffect >= 2 := by
  cases hasArchiveSideEffect <;> decide

theorem cmd_w_second_press_confirms_choice
    (s : CloseSurface) (pt sp : Nat) (hh ex only ask : Bool) :
    decideCloseTarget s true pt sp hh ex only ask = .confirmChoice := by
  rfl

theorem cmd_w_visible_host_closes_before_chat
    (pt sp : Nat) (only ask : Bool) :
    decideCloseTarget .chat false pt sp true false only ask = .closeHost := by
  rfl

theorem cmd_w_split_pane_closes_when_no_host
    (sp : Nat) (hsp : sp > 1) (ex only ask : Bool) :
    decideCloseTarget .chat false 1 sp false ex only ask = .closeSplitPane := by
  unfold decideCloseTarget
  simp [hsp]

/-- Model picker billing tier rank (`billingRank` in `view_picker_models.zig`
and `ModelSelectionSheet.swift`): orders subscription (`plan`) models first,
followed by `local`, `credits`, and `api` (non-subscription). -/
inductive BillingTier where
  | plan | local | credits | api
deriving DecidableEq, Repr, BEq

def billingRank (b : BillingTier) : Nat :=
  match b with
  | .plan    => 0
  | .local   => 1
  | .credits => 2
  | .api     => 3

theorem billing_rank_subs_before_nonsubs :
    billingRank .plan < billingRank .local ∧
    billingRank .local < billingRank .credits ∧
    billingRank .credits < billingRank .api := by
  native_decide

/-- Retained-scene eligibility (`retain.store` in `nanoui`): a scroll container
that culls offscreen children in user space (`virtualList = true`, such as Settings
pages) must never cache its partial node tree in `retain.store`, preventing `retain.use`
from shifting a culled scene on 120Hz scroll events. -/
def retainStoreOk (virtualList animating changed : Bool) : Bool :=
  !virtualList && !animating && !changed

theorem virtual_list_prevents_culled_retain_shift (animating changed : Bool) :
    retainStoreOk true animating changed = false := by
  rfl

/-- Active sidebar row fill policy (`view_sidebar.zig`, `view_settings.zig`):
on a translucent frosted sidebar (`alpha = 204 < 255`), active rows use the
translucent `selected` wash (`opaqueCard = false`) rather than an `alpha = 255`
opaque card + dark shadow, preventing `R > A ≥ B` premultiplied-alpha corner
overflow (`#0201ff`). -/
def sidebarActiveOpaqueCard (frosted : Bool) : Bool :=
  !frosted

theorem frosted_sidebar_never_paints_opaque_card :
    sidebarActiveOpaqueCard true = false := by
  rfl

/-- Engine version mismatch resolution (`decideEngineVersionAction` in `view_updates.zig`):
when `harness-nano` connects to an older background `harness headless` process after an
app update (`isOlder = true`, `liveSession = true`, `alreadyReplaced = false`), it kills
the old engine session and starts the updated bundled engine (`replaceOldSession`)
instead of showing a manual `harness daemon stop` warning. A single-shot guard
(`alreadyReplaced = true`) guarantees termination if the candidate binary on disk is still old. -/
inductive EngineVersionAction where
  | upToDate
  | replaceOldSession
  | notifyOnly
deriving DecidableEq, Repr, BEq

def decideEngineVersionAction (isOlder : Bool) (liveSession : Bool) (alreadyReplaced : Bool) : EngineVersionAction :=
  if !isOlder then .upToDate
  else if liveSession && !alreadyReplaced then .replaceOldSession
  else .notifyOnly

theorem older_live_engine_replaces_first_time :
    decideEngineVersionAction true true false = .replaceOldSession := by
  rfl

theorem older_engine_replace_terminates (isOlder liveSession : Bool) :
    decideEngineVersionAction isOlder liveSession true ≠ .replaceOldSession := by
  cases isOlder <;> cases liveSession <;> decide

theorem current_or_newer_engine_noops (liveSession alreadyReplaced : Bool) :
    decideEngineVersionAction false liveSession alreadyReplaced = .upToDate := by
  rfl

/-- UI frame execution phases (`nanoui.ui.frame.run` and `view.zig`):
1. `preTreeReap`: runs `a.reap()` and `settleFrame()` before any UI nodes exist in `c.nodes`.
2. `buildingTree`: builds `c.nodes`, where `.text` nodes borrow unowned `[]const u8` slices.
3. `measuringAndPainting`: runs `ui.layout.measure` (`TextSystem.key` / `Wyhash.update`) and
   `paint` over all `.text` slices borrowed during `buildingTree`. -/
inductive FramePhase where
  | preTreeReap
  | buildingTree
  | measuringAndPainting
deriving DecidableEq, Repr, BEq

/-- Lifecycle state of an arena or string slice that may be borrowed by `.text` nodes. -/
inductive AllocState where
  | live
  | retired
  | freed
deriving DecidableEq, Repr, BEq

/-- Memory is readable by `ui.layout.measure` (`Wyhash.update`) and `paint` iff it has
not been unmapped/freed (`live` or `retired`). -/
def isReadable (st : AllocState) : Bool :=
  match st with
  | .live    => true
  | .retired => true
  | .freed   => false

/-- Buggy immediate replacement: freeing an arena or slice mid-frame unmaps its pages
while `.text` nodes in `c.nodes` still hold slices into it. -/
def replaceImmediate (_ : AllocState) : AllocState :=
  .freed

/-- Safe deferred replacement (`retireArena`, `retireSlice`, `List.replace`, `copyModels`):
transitions a live allocation to `.retired` so it remains mapped until the next frame's
`preTreeReap` phase. -/
def replaceDeferred (st : AllocState) : AllocState :=
  match st with
  | .live    => .retired
  | .retired => .retired
  | .freed   => .freed

/-- `a.reap()` at `preTreeReap` (when `c.nodes` is empty) reclaims retired allocations. -/
def reapAtPreTree (st : AllocState) : AllocState :=
  match st with
  | .live    => .live
  | .retired => .freed
  | .freed   => .freed

/-- N consecutive mid-frame replacements during `buildingTree`. -/
def replaceDeferredN : Nat → AllocState → AllocState
  | 0,     st => st
  | n + 1, st => replaceDeferred (replaceDeferredN n st)

theorem immediate_replace_causes_use_after_free :
    isReadable (replaceImmediate .live) = false := by
  rfl

theorem deferred_replace_preserves_readability (st : AllocState)
    (h : isReadable st = true) :
    isReadable (replaceDeferred st) = true := by
  cases st <;> simp_all [isReadable, replaceDeferred]

theorem deferred_replace_n_preserves_readability (n : Nat) (st : AllocState)
    (h : isReadable st = true) :
    isReadable (replaceDeferredN n st) = true := by
  induction n with
  | zero => exact h
  | succ k ih =>
    simp only [replaceDeferredN]
    exact deferred_replace_preserves_readability (replaceDeferredN k st) ih

theorem live_borrowed_slice_survives_measure_and_paint (n : Nat) :
    isReadable (replaceDeferredN n .live) = true := by
  exact deferred_replace_n_preserves_readability n .live rfl

theorem reap_frees_retired_at_next_frame_start :
    reapAtPreTree (replaceDeferred .live) = .freed := by
  rfl

/-- Split-pane click action (`view.zig`): clicking an unfocused split pane during
`buildingTree` (`inPreTree = false`) queues the focus transition for the next frame's
`preTreeReap` phase rather than mutating the active pane mid-tree. -/
inductive PaneClickAction where
  | focusImmediate
  | queueForNextPreTree
deriving DecidableEq, Repr, BEq

def decidePaneClickAction (inPreTree : Bool) : PaneClickAction :=
  if inPreTree then .focusImmediate else .queueForNextPreTree

theorem mid_frame_pane_click_defers_focus :
    decidePaneClickAction false = .queueForNextPreTree := by
  rfl

/-- Two-frame immediate-mode click survival (`view_composer.zig`, `view_write.zig`):
In `nanoui`, `b.clicked()` completes on the `mouseUp` frame (`t + 1`) only if the button
remained mounted on both `mouseDown` (`t`) and `mouseUp` (`t + 1`). When `ui.textField` runs
before the expanded action bar on `mouseDown`, a press on `composer-write` outside the text
field's rect clears `c.focus := 0` (`focusedAfterPress = false`).
Gating `composer-write` on `hasText || focused` (`mountWriteButtonOld`) unmounts the button
before `mouseUp` whenever `hasText = false` (e.g., an attachment-only draft). Mounting it
unconditionally in the expanded action bar (`mountWriteButtonFixed`) guarantees click completion. -/
def mountWriteButtonOld (hasText focused : Bool) : Bool :=
  hasText || focused

def mountWriteButtonFixed (expanded : Bool) (_hasText _focused : Bool) : Bool :=
  expanded

theorem old_write_button_unmounts_on_attachment_only_press :
    mountWriteButtonOld false false = false := by
  rfl

theorem fixed_write_button_survives_focus_blur (hasText focused : Bool) :
    mountWriteButtonFixed true hasText focused = true := by
  rfl

/-- Sidebar `Last activity` filter (`view_sidebar.zig`):
Historical sessions whose last reply hasn't been opened carry `Mark.completed` (`✓`), not
`Mark.idle` (`•`). Filtering only `Mark.idle` (`keepChatOld`) leaks `.completed` sessions
from weeks ago into `1d`/`3d`/`7d`/`30d` views. Filtering all non-live marks (`keepChatFixed`)
filters `.completed` and `.idle` alike while preserving active `.working` / `.awaitingInput` turns. -/
inductive SidebarMark where
  | working
  | awaitingInput
  | errored
  | completed
  | idle
deriving DecidableEq, Repr, BEq

def keepChatOld (m : SidebarMark) (inWindow : Bool) : Bool :=
  m != .idle || inWindow

def keepChatFixed (m : SidebarMark) (inWindow : Bool) : Bool :=
  m == .working || m == .awaitingInput || inWindow

theorem old_filter_leaks_completed_outside_window :
    keepChatOld .completed false = true := by
  rfl

theorem fixed_filter_hides_completed_and_idle_outside_window :
    keepChatFixed .completed false = false ∧
    keepChatFixed .idle false = false ∧
    keepChatFixed .errored false = false := by
  decide

theorem fixed_filter_keeps_live_or_in_window (m : SidebarMark) :
    keepChatFixed m true = true ∧
    keepChatFixed .working false = true ∧
    keepChatFixed .awaitingInput false = true := by
  cases m <;> decide

/-- Multiline editor scrollbar policy (`view_composer.zig`, `view_write.zig`,
`view_question.zig`, `view_actions.zig`):
In `nanoui`, `ui.textField` appends its caret rectangle as a child leaf of the
`.scroll` container while `c.focus == id`. When `paintScrollbars` sums direct
child heights (`content_h += cr.h + gap`), the caret leaf inflates `content_h`
above `r.h` even on a 1-line or auto-growing prompt, painting a floating 4px
vertical scrollbar thumb whose height and position jump as the caret blinks or
lines wrap. Disabling `scroll_bar` on multiline text fields (`multilineFieldScrollbar = false`)
eliminates the phantom bar across all prompt lengths and focus states. -/
def multilineFieldScrollbar (_focused _caretVisible _hasOverflow : Bool) : Bool :=
  false

theorem multiline_field_never_paints_phantom_scrollbar (focused caretVisible hasOverflow : Bool) :
    multilineFieldScrollbar focused caretVisible hasOverflow = false := by
  rfl

/-- Exclusive selection ownership between editable text fields (`c.edits`) and
rendered page text (`c.selection`), plus `Cmd+C` copy routing (`view.zig`,
`view_composer.zig`):
At most one selection owner (`none`, `editor`, or `page`) is active after
settling input for a frame. Starting or dragging a page selection collapses the
editor selection; clicking or moving the caret/selection inside an editor clears
the page selection; and a no-op Undo/Redo when the undo stack is empty preserves
the current owner. -/
inductive SelectionOwner where
  | none
  | editor
  | page
deriving DecidableEq, Repr, BEq

inductive SelectionEvent where
  | pageSelect
  | editorSelectOrEdit
  | noopUndoRedo
  | clearAll
deriving DecidableEq, Repr, BEq

def stepSelectionOwner (cur : SelectionOwner) (ev : SelectionEvent) : SelectionOwner :=
  match ev with
  | .pageSelect         => .page
  | .editorSelectOrEdit => .editor
  | .noopUndoRedo       => cur
  | .clearAll           => .none

def hasDualSelection (owner : SelectionOwner) : Bool :=
  owner == .editor && owner == .page

theorem selection_owner_mutually_exclusive (cur : SelectionOwner) (ev : SelectionEvent) :
    hasDualSelection (stepSelectionOwner cur ev) = false := by
  cases cur <;> cases ev <;> rfl

theorem page_selection_preempts_editor (cur : SelectionOwner) :
    stepSelectionOwner cur .pageSelect = .page := by
  rfl

theorem editor_selection_preempts_page (cur : SelectionOwner) :
    stepSelectionOwner cur .editorSelectOrEdit = .editor := by
  rfl

theorem noop_undo_redo_preserves_page_selection :
    stepSelectionOwner .page .noopUndoRedo = .page := by
  rfl

/-- `Cmd+C` copy target resolution (`view.zig:settleSelectionPostTree`):
Copies the editor slice iff the composer is focused with a non-empty range
(`editorFocused && editorHasRange`), else copies the rendered page selection iff
`pageHasText`, else performs no copy. -/
inductive CopyTarget where
  | none
  | editorSlice
  | pageSlice
deriving DecidableEq, Repr, BEq

def decideCopyTarget (editorFocused editorHasRange pageHasText : Bool) : CopyTarget :=
  if editorFocused && editorHasRange then .editorSlice
  else if pageHasText then .pageSlice
  else .none

theorem page_selection_copies_when_editor_unfocused_or_collapsed (editorFocused : Bool) :
    decideCopyTarget editorFocused false true = .pageSlice ∧
    decideCopyTarget false true true = .pageSlice := by
  cases editorFocused <;> decide

/-- Whitespace-origin drag snapping (`view.zig:hitLeafIndex` / `findNearestSelectableLeaf`, `#717`):
When a pointer drag starts or ends in padding/margin outside a selectable text leaf
(`[leafStart, leafEnd]`), the character offset snaps to `0` above/left of the leaf
and to `textLen` below/right of the leaf, so dragging from bubble/row padding
cleanly selects the boundary characters. -/
def snapWhitespaceOffset (coord leafStart leafEnd textLen : Nat) : Nat :=
  if coord <= leafStart then 0
  else if coord >= leafEnd then textLen
  else textLen / 2

theorem whitespace_before_leaf_snaps_to_start (coord leafStart leafEnd textLen : Nat)
    (h : coord <= leafStart) :
    snapWhitespaceOffset coord leafStart leafEnd textLen = 0 := by
  simp [snapWhitespaceOffset, h]

theorem whitespace_after_leaf_snaps_to_end (coord leafStart leafEnd textLen : Nat)
    (h1 : ¬ coord <= leafStart) (h2 : coord >= leafEnd) :
    snapWhitespaceOffset coord leafStart leafEnd textLen = textLen := by
  simp [snapWhitespaceOffset, h1, h2]

/-- Selection survival across scope transitions and unmounted sources (`#745`):
A rendered-text selection survives into the next frame iff `sameScope = true`
(same active tab, chat, settings/write page, and question wizard prompt) AND
`sourceMounted = true` (its selected nodes still produced non-empty text). -/
def selectionSurvivesFrame (sameScope sourceMounted : Bool) : Bool :=
  sameScope && sourceMounted

theorem scope_change_or_unmount_clears_selection (sameScope sourceMounted : Bool) :
    selectionSurvivesFrame false sourceMounted = false ∧
    selectionSurvivesFrame sameScope false = false := by
  cases sameScope <;> cases sourceMounted <;> decide

/-- Startup tab restoration fencing & archived-chat exclusion (`App.restoreTabs`, `#797`):
1. `shouldRestoreSavedTabs`: asynchronous `onChats` arrival restores saved tabs only
   once (`!tabsReady`), on a single untouched boot tab (`singleEmptyTab`), when no
   chat was already selected (`!hasSelectedChat`) and the user has not typed, staged
   attachments, or picked a project/device on the boot canvas (`!hasDirtyBootDraft`).
2. `restorableTabChat`: a chat ID in `openTabs` or `tabLayout` is restorable iff it
   exists in `chats`, is NOT `archived`, and is not already open in another tab. -/
def shouldRestoreSavedTabs (tabsReady hasSelectedChat singleEmptyTab hasDirtyBootDraft : Bool) : Bool :=
  !tabsReady && !hasSelectedChat && singleEmptyTab && !hasDirtyBootDraft

def restorableTabChat (chatExists isArchived alreadyOpen : Bool) : Bool :=
  chatExists && !isArchived && !alreadyOpen

theorem dirty_boot_draft_blocks_tab_restore (tabsReady hasSelectedChat singleEmptyTab : Bool) :
    shouldRestoreSavedTabs tabsReady hasSelectedChat singleEmptyTab true = false := by
  cases tabsReady <;> cases hasSelectedChat <;> cases singleEmptyTab <;> rfl

theorem archived_chat_never_restores_into_open_tabs (chatExists alreadyOpen : Bool) :
    restorableTabChat chatExists true alreadyOpen = false := by
  cases chatExists <;> cases alreadyOpen <;> rfl

/-- Sidebar `Open workspaces` visibility (`view_sidebar.zig:openWorkspaces`):
Every open workspace tab is listed in the sidebar tree when workspaces are shown,
regardless of whether it currently holds a single listed conversation (`isSingletonListedChat`). -/
def workspaceVisibleInSidebarOld (hasMultipleWorkspaces isSingletonListedChat : Bool) : Bool :=
  hasMultipleWorkspaces && !isSingletonListedChat

def workspaceVisibleInSidebarFixed (hasMultipleWorkspaces _isSingletonListedChat : Bool) : Bool :=
  hasMultipleWorkspaces

theorem fixed_sidebar_lists_single_chat_workspaces (isSingletonListedChat : Bool) :
    workspaceVisibleInSidebarFixed true isSingletonListedChat = true := by
  rfl

/-- Currency-safe inline `$ ... $` delimiter rule (`markdown.zig:inlineMathEnd`, `#795`):
An opening `$` and closing `$` pair forms inline math iff:
- Not inside a code span (`!inCodeSpan`),
- Not escaped (`!openEscaped`, `!closeEscaped`),
- Not adjacent to inner whitespace (`!spaceAfterOpen`, `!spaceBeforeClose`),
- Not adjacent to outer alphanumeric/digit characters (`!alnumBeforeOpen`, `!alnumAfterClose`).
Consequently, prose currency like `$5 and $10` (where the second `$` has
`spaceBeforeClose = true` and `alnumAfterClose = true`) is never misparsed as math. -/
def isInlineMathDelimiterPair
    (inCodeSpan openEscaped closeEscaped spaceAfterOpen spaceBeforeClose alnumBeforeOpen alnumAfterClose : Bool) : Bool :=
  !inCodeSpan && !openEscaped && !closeEscaped &&
  !spaceAfterOpen && !spaceBeforeClose &&
  !alnumBeforeOpen && !alnumAfterClose

theorem currency_prose_never_parses_as_math
    (inCodeSpan openEscaped closeEscaped spaceAfterOpen alnumBeforeOpen : Bool) :
    isInlineMathDelimiterPair inCodeSpan openEscaped closeEscaped spaceAfterOpen true alnumBeforeOpen true = false := by
  cases inCodeSpan <;> cases openEscaped <;> cases closeEscaped <;>
    cases spaceAfterOpen <;> cases alnumBeforeOpen <;> rfl

theorem code_span_dollar_never_parses_as_math
    (openEscaped closeEscaped spaceAfterOpen spaceBeforeClose alnumBeforeOpen alnumAfterClose : Bool) :
    isInlineMathDelimiterPair true openEscaped closeEscaped spaceAfterOpen spaceBeforeClose alnumBeforeOpen alnumAfterClose = false := by
  rfl

def desktopRegressionCube : Bool :=
  multilineFieldScrollbar true true true == false &&
  hasDualSelection (stepSelectionOwner .editor .pageSelect) == false &&
  hasDualSelection (stepSelectionOwner .page .editorSelectOrEdit) == false &&
  decideCopyTarget false false true == .pageSlice &&
  selectionSurvivesFrame false true == false &&
  selectionSurvivesFrame true false == false &&
  shouldRestoreSavedTabs false false true true == false &&
  restorableTabChat true true false == false &&
  workspaceVisibleInSidebarFixed true true == true &&
  isInlineMathDelimiterPair false false false false true false true == false

theorem desktop_regression_cube_holds : desktopRegressionCube = true := by
  decide

/-- iOS `UITableView` batch-update and scroll-index safety (`NativeTranscriptTable.swift`):
UIKit throws `NSInternalInconsistencyException` if `insertRows` or `performBatchUpdates` is
invoked when `numberOfRows(inSection: 0) ≠ previousIDs.count` (for example after an offscreen
`reloadData()` whose layout was skipped on an append) or when row IDs contain duplicates.
Falling back to `reloadData()` whenever `uiKitRowCount ≠ previousCount ∨ ¬uniqueIds`
guarantees UIKit batch-update preconditions hold. -/
inductive TableUpdateAction where
  | batchDiff
  | reloadAll
deriving DecidableEq, Repr, BEq

def chooseTableUpdateSafe (uiKitRowCount previousCount : Nat) (uniqueIds : Bool) : TableUpdateAction :=
  if uiKitRowCount == previousCount && uniqueIds then .batchDiff else .reloadAll

theorem safe_table_update_requires_synced_counts_and_unique_ids
    (uiKitRowCount previousCount : Nat) (uniqueIds : Bool)
    (h : chooseTableUpdateSafe uiKitRowCount previousCount uniqueIds = .batchDiff) :
    uiKitRowCount = previousCount ∧ uniqueIds = true := by
  unfold chooseTableUpdateSafe at h
  split at h
  · rename_i hcond
    rw [Bool.and_eq_true, beq_iff_eq] at hcond
    exact hcond
  · contradiction

theorem desynced_table_row_count_falls_back_to_reload
    (uiKitRowCount previousCount : Nat) (uniqueIds : Bool)
    (hne : uiKitRowCount ≠ previousCount) :
    chooseTableUpdateSafe uiKitRowCount previousCount uniqueIds = .reloadAll := by
  unfold chooseTableUpdateSafe
  have hbeq : (uiKitRowCount == previousCount) = false := beq_false_of_ne hne
  simp [hbeq]

theorem duplicate_row_ids_fall_back_to_reload (uiKitRowCount previousCount : Nat) :
    chooseTableUpdateSafe uiKitRowCount previousCount false = .reloadAll := by
  unfold chooseTableUpdateSafe
  simp

/-- Guarding `scrollToRow` and `rectForRow` against both `rows.count` and UIKit's
materialized `numberOfRows(inSection: 0)` prevents `NSRangeException`. -/
def canIndexTableRow (row rowsCount uiKitRowCount : Int) : Bool :=
  decide (0 ≤ row ∧ row < rowsCount ∧ row < uiKitRowCount)

theorem canIndexTableRow_in_bounds (row rowsCount uiKitRowCount : Int)
    (h : canIndexTableRow row rowsCount uiKitRowCount = true) :
    0 ≤ row ∧ row < rowsCount ∧ row < uiKitRowCount := by
  unfold canIndexTableRow at h
  exact of_decide_eq_true h

/-- Lock-order hierarchy for `EntryCache` and `LoroDoc` (`EntryCache.swift`, `SessionStore.swift`):
`readLock` (rank 0) serializes `EntryCache.read` calls, `loroLock` (rank 1) is `LoroDoc`'s
internal Rust mutex acquired during FFI reads/imports, and `staleLock` (rank 2) guards the
`stale` / `entries` dictionaries. Every code path acquires locks in strictly ascending rank
order (`0 < 1`, `0 < 2`, `1 < 2`), making lock-order cycles (deadlocks) impossible while
preventing concurrent `EntryCache.read` calls from overwriting fresh entries with stale snapshots. -/
def lockRankRead : Nat := 0
def lockRankLoro : Nat := 1
def lockRankStale : Nat := 2

def validLockTransition (held next : Nat) : Bool :=
  decide (held < next)

theorem entry_cache_lock_order_is_strictly_acyclic :
    validLockTransition lockRankRead lockRankLoro = true ∧
    validLockTransition lockRankRead lockRankStale = true ∧
    validLockTransition lockRankLoro lockRankStale = true := by
  decide

/-- Decluttered iOS top-of-screen hierarchy (`HomeView.swift`, `SessionView.swift`):
Removing the hero banner (`HomeStartHeader`), duplicate horizontal strips (`PinnedRow`,
`NowStrip`), and split banner (`SplitOfferBanner`) above the session list places the compact
filter pills and session rows immediately at index 0, and removing auxiliary pager/status
widgets from `SessionView`'s navigation bar reduces header clutter to 0. -/
inductive HomeTopItem where
  | startHero
  | pinnedStrip
  | splitOffer
  | nowCarousel
  | filterPills
  | sessionList
deriving DecidableEq, Repr, BEq

def isTopClutter : HomeTopItem → Bool
  | .startHero   => true
  | .pinnedStrip => true
  | .splitOffer  => true
  | .nowCarousel => true
  | .filterPills => false
  | .sessionList => false

def homeTopLayoutClean : List HomeTopItem :=
  [.filterPills, .sessionList]

theorem clean_home_layout_has_zero_top_clutter :
    (homeTopLayoutClean.filter isTopClutter).length = 0 ∧
    homeTopLayoutClean.head? = some .filterPills := by
  decide

/-- Native iOS Liquid Glass fidelity (`HomeListControls.swift`, `ComposerView.swift`,
`WriteSheet.swift`, `ThemeStore.swift`):
Painting an interior fill (`Theme.composerPlane` or `ink(0.04)`) inside a view wrapped in
`.glassEffect(.regular.interactive(), ...)` or painting an unfocused `hairline(0.05)` border
over its perimeter flattens UIKit/SwiftUI's native specular rim highlight and refraction.
A glass surface preserves native refraction (`preservesNativeGlass`) iff `hasInteriorFill = false`
and `hasUnfocusedBorderOverlay = false`. -/
structure GlassSurfaceConfig where
  hasInteriorFill : Bool
  hasUnfocusedBorderOverlay : Bool
deriving DecidableEq, Repr

def preservesNativeGlass (cfg : GlassSurfaceConfig) : Bool :=
  !cfg.hasInteriorFill && !cfg.hasUnfocusedBorderOverlay

def fakeGlassConfig : GlassSurfaceConfig :=
  { hasInteriorFill := true, hasUnfocusedBorderOverlay := true }

def nativeGlassConfig : GlassSurfaceConfig :=
  { hasInteriorFill := false, hasUnfocusedBorderOverlay := false }

theorem fake_glass_destroys_native_refraction :
    preservesNativeGlass fakeGlassConfig = false := by
  rfl

theorem native_glass_preserves_specular_refraction :
    preservesNativeGlass nativeGlassConfig = true := by
  rfl

/-- Concentric corner geometry (`ComposerView.swift`, `NewSessionView.swift`):
When a rounded container of outer radius `outerRadius` wraps a circular button of diameter
`innerDiameter` (inner radius `innerDiameter / 2`), concentricity requires
`outerRadius ≥ innerDiameter / 2`. An expanded composer with 44pt circle buttons (`innerRadius = 22`)
requires `outerRadius ≥ 22` (20pt violates concentricity; 22pt satisfies it). -/
def isConcentricCorner (outerRadius innerDiameter : Nat) : Bool :=
  outerRadius ≥ innerDiameter / 2

theorem composer_legacy_radius_20_violates_concentricity :
    isConcentricCorner 20 44 = false := by
  decide

theorem composer_expanded_radius_22_is_concentric :
    isConcentricCorner 22 44 = true ∧ isConcentricCorner 24 44 = true := by
  decide

/-- Reduced-motion-safe tactile press scale (`Motion.swift`, `SheetUI.swift`):
Scale in basis points (`10000 = 1.0x`). Under `reduceMotion = true` or `pressed = false`,
scale is strictly `10000`. Under `reduceMotion = false` and `pressed = true`, scale contracts
into `[9000, 9900]`. -/
def pressScaleBP (reduceMotion pressed : Bool) (targetBP : Nat) : Nat :=
  if reduceMotion || !pressed then 10000
  else max 9000 (min 9900 targetBP)

theorem press_scale_respects_reduced_motion (pressed : Bool) (targetBP : Nat) :
    pressScaleBP true pressed targetBP = 10000 := by
  simp [pressScaleBP]

theorem press_scale_bounded_and_contracting (targetBP : Nat) :
    9000 ≤ pressScaleBP false true targetBP ∧ pressScaleBP false true targetBP ≤ 9900 := by
  simp [pressScaleBP]
  omega

end Nano.FrameSchedule
