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
2. When focused on `.chat` inside a split (`splitPanes > 1`), `Cmd+W` always
   closes the focused split pane (`closeSplitPane`), never a background host tab.
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
    if paneTabs > 1 then .closePaneTab
    else if splitPanes > 1 then .closeSplitPane
    else if hasHost && !expanded then .closeHost
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

theorem cmd_w_split_pane_takes_precedence_over_host
    (sp : Nat) (hsp : sp > 1) (hh ex only ask : Bool) :
    decideCloseTarget .chat false 1 sp hh ex only ask = .closeSplitPane := by
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

end Nano.FrameSchedule
