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

end Nano.FrameSchedule
