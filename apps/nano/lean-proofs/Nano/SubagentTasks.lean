/-
  Subagent & Task Management Kernel (`SubagentTasks`).

  Models the pure state machine and geometry shared by `apps/nano/src/agent_work.zig`
  and `apps/nano/src/view_agent_work.zig`:
  1. `resolveAgentState`: merges live cross-turn `WatchToolProgress` states
     (`running | completed | failed | cancelled | disconnected`), persisted
     `subagentStatus` (`running | completed | failed | stopped`), and tool
     resolution (`resolved`, `isError`, `turnLive`) without ever leaving an
     untracked subagent stuck in `running` after its turn settles.
  2. `stepStates`: maps the latest `Todo` checklist (`done : List Bool`),
     `turnLive`, and `hasQuestion` (`AsksFirst`) into `StepState` rows with at
     most one `active` step, and zero `active` steps once the turn settles.
  3. `footerWidth` & `placeCard`: bounds the composer-footer Agent Work chip
     (switching from 12px step dots with 6px connectors to tabular `done/total`
     above `maxFooterDots = 6`) and clamps the 320px hover/click popover card
     inside narrow or split panes.
-/

namespace Nano.SubagentTasks

inductive LiveProgressState where
  | running
  | completed
  | failed
  | cancelled
  | disconnected
deriving DecidableEq, Repr, BEq

inductive DocSubagentStatus where
  | running
  | completed
  | failed
  | stopped
deriving DecidableEq, Repr, BEq

inductive AgentState where
  | running
  | done
  | failed
  | stopped
deriving DecidableEq, Repr, BEq

inductive StepState where
  | done
  | active
  | pending
  | asksFirst
deriving DecidableEq, Repr, BEq

/-- Live `WatchToolProgress` overrides stale persisted doc state so cross-turn
ACP updates advance immediately; when neither is present, a settled turn never
invents a still-running subagent. -/
def resolveAgentState
    (live : Option LiveProgressState)
    (doc : Option DocSubagentStatus)
    (resolved isError turnLive : Bool) : AgentState :=
  match live with
  | some .running      => .running
  | some .completed    => .done
  | some .failed       => .failed
  | some .cancelled    => .stopped
  | some .disconnected => .stopped
  | none =>
    match doc with
    | some .completed => .done
    | some .failed    => .failed
    | some .stopped   => .stopped
    | some .running   =>
      if !turnLive && resolved then
        if isError then .failed else .done
      else .running
    | none =>
      if isError then .failed
      else if resolved || !turnLive then .done
      else .running

/-- Theorem: with no live ACP progress or explicit running doc status, a
finished turn never leaves a subagent row in `.running`. -/
theorem settled_turn_never_ghost_runs
    (resolved isError : Bool) :
    resolveAgentState none none resolved isError false ≠ .running := by
  cases resolved <;> cases isError <;> decide

/-- Theorem: live ACP `WatchToolProgress` always determines the subagent state,
regardless of stale doc status or unresolved parent part flags. -/
theorem live_progress_authoritative
    (s : LiveProgressState)
    (d1 d2 : Option DocSubagentStatus)
    (r1 r2 e1 e2 l1 l2 : Bool) :
    resolveAgentState (some s) d1 r1 e1 l1
      = resolveAgentState (some s) d2 r2 e2 l2 := by
  cases s <;> rfl

/-- Assigns `StepState` to each item in the latest `Todo` list, promoting only
the first unfinished step while `turnLive` holds, and appending a gated
`asksFirst` step when an unresolved question is waiting on the user. -/
def assignTodoSteps : List Bool → Bool → List StepState
  | [], _ => []
  | true :: rest, canActivate => .done :: assignTodoSteps rest canActivate
  | false :: rest, true => .active :: assignTodoSteps rest false
  | false :: rest, false => .pending :: assignTodoSteps rest false

def stepStates (items : List Bool) (turnLive hasQuestion : Bool) : List StepState :=
  let base := assignTodoSteps items turnLive
  if items.isEmpty then []
  else if hasQuestion then base ++ [.asksFirst]
  else base

def countActive : List StepState → Nat
  | [] => 0
  | .active :: rest => 1 + countActive rest
  | _ :: rest => countActive rest

theorem countActive_append (xs ys : List StepState) :
    countActive (xs ++ ys) = countActive xs + countActive ys := by
  induction xs with
  | nil => simp [countActive]
  | cons x rest ih =>
    cases x <;> simp [countActive, ih] <;> omega

theorem assign_inactive_zero (items : List Bool) :
    countActive (assignTodoSteps items false) = 0 := by
  induction items with
  | nil => rfl
  | cons b rest ih =>
    cases b <;> simp [assignTodoSteps, countActive, ih]

theorem assign_at_most_one_active (items : List Bool) (canActivate : Bool) :
    countActive (assignTodoSteps items canActivate) ≤ 1 := by
  induction items generalizing canActivate with
  | nil => simp [assignTodoSteps, countActive]
  | cons b rest ih =>
    cases b with
    | true =>
      simpa [assignTodoSteps, countActive] using ih canActivate
    | false =>
      have h0 := assign_inactive_zero rest
      cases canActivate <;> simp [assignTodoSteps, countActive, h0]

/-- Theorem: at most one step is ever `.active` in the timeline. -/
theorem step_timeline_at_most_one_active
    (items : List Bool) (turnLive hasQuestion : Bool) :
    countActive (stepStates items turnLive hasQuestion) ≤ 1 := by
  unfold stepStates
  split
  · simp [countActive]
  · split
    · have h := assign_at_most_one_active items turnLive
      rw [countActive_append]
      simp [countActive]
      exact h
    · exact assign_at_most_one_active items turnLive

/-- Theorem: a settled turn has zero `.active` steps. -/
theorem settled_turn_zero_active_steps
    (items : List Bool) (hasQuestion : Bool) :
    countActive (stepStates items false hasQuestion) = 0 := by
  unfold stepStates
  split
  · rfl
  · split
    · have h := assign_inactive_zero items
      rw [countActive_append]
      simp [countActive, h]
    · exact assign_inactive_zero items

/-- Footer indicator width rules (`MAX_FOOTER_DOTS = 6`, 12px dots, 6px links,
6px horizontal pill padding). Above 6 steps it switches to compact `done/total`
text (`≤ 56px`), keeping the footer pill bounded for arbitrarily long plans. -/
def maxFooterDots : Nat := 6
def dotDiameter : Nat := 12
def dotLink : Nat := 6
def pillPadX : Nat := 12
def fractionCapW : Nat := 56

def footerStepsWidth (stepCount : Nat) : Nat :=
  if stepCount == 0 then 0
  else if stepCount ≤ maxFooterDots then
    pillPadX + stepCount * dotDiameter + (stepCount - 1) * dotLink
  else
    pillPadX + fractionCapW

/-- Theorem: regardless of how many TODO items an agent creates (even 50+),
the footer step indicator never exceeds 114px (`6 * 12 + 5 * 6 + 12 = 114`). -/
theorem footer_steps_width_bounded (n : Nat) :
    footerStepsWidth n ≤ 114 := by
  unfold footerStepsWidth maxFooterDots dotDiameter dotLink pillPadX fractionCapW
  split
  · omega
  · split <;> omega

structure CardBox where
  x : Nat
  y : Nat
  w : Nat
  h : Nat
deriving DecidableEq, Repr, BEq

def margin : Nat := 8
def defaultCardW : Nat := 320

/-- Places the Agent Work popover card above the footer chip, clamping width
and coordinates so it stays inside `[margin, winW - margin] × [margin, winH - margin]`
even in narrow 3-pane splits. -/
def placeCard (winW winH anchorRight anchorTop desiredH : Nat) : CardBox :=
  let availW := winW - min winW (2 * margin)
  let availH := winH - min winH (2 * margin)
  let w := min defaultCardW availW
  let h := min desiredH availH
  let rawX := anchorRight - min anchorRight w
  let maxX := margin + (availW - w)
  let x := max margin (min rawX maxX)
  let aboveTop := anchorTop - min anchorTop (h + margin)
  let maxY := margin + (availH - h)
  let y := max margin (min aboveTop maxY)
  { x := x, y := y, w := w, h := h }

/-- Theorem: whenever the window has at least `2 * margin` (`16px`), the Agent
Work card stays completely within the window margins on both axes. -/
theorem card_within_window
    (winW winH anchorRight anchorTop desiredH : Nat)
    (hw : 2 * margin ≤ winW) (hh : 2 * margin ≤ winH) :
    let b := placeCard winW winH anchorRight anchorTop desiredH
    margin ≤ b.x ∧ b.x + b.w + margin ≤ winW ∧
    margin ≤ b.y ∧ b.y + b.h + margin ≤ winH := by
  simp only [placeCard, margin, defaultCardW] at hw hh ⊢
  omega

/-- Finite exhaustive verification cubes. -/
def liveDomain : List (Option LiveProgressState) :=
  [none, some .running, some .completed, some .failed, some .cancelled, some .disconnected]

def docDomain : List (Option DocSubagentStatus) :=
  [none, some .running, some .completed, some .failed, some .stopped]

def bools : List Bool := [false, true]

def todoLists : List (List Bool) :=
  [[], [false], [true], [true, false], [true, false, false],
   [true, true, false, false], [true, true, true, true, false, false, false]]

def winWidths : List Nat := [240, 360, 480, 720, 1240]
def winHeights : List Nat := [320, 540, 820]

def subagentCells : Nat :=
  liveDomain.length * docDomain.length * 8
  + todoLists.length * 4
  + 32
  + winWidths.length * winHeights.length * 4

def agentStateCube : Bool :=
  liveDomain.all (fun l =>
    docDomain.all (fun d =>
      bools.all (fun r =>
        bools.all (fun e =>
          bools.all (fun tl =>
            let st := resolveAgentState l d r e tl
            (if l == none && d == none && !tl then st != .running else true) &&
            (if l == some .running then st == .running else true) &&
            (if l == some .completed then st == .done else true) &&
            (if l == some .failed then st == .failed else true))))))

def stepTimelineCube : Bool :=
  todoLists.all (fun items =>
    bools.all (fun tl =>
      bools.all (fun q =>
        let s := stepStates items tl q
        decide (countActive s ≤ 1) &&
        (if !tl then decide (countActive s == 0) else true) &&
        decide (footerStepsWidth s.length ≤ 114))))

def cardPlacementCube : Bool :=
  winWidths.all (fun ww =>
    winHeights.all (fun wh =>
      [80, 320, ww].all (fun ax =>
        [200, wh - 32].all (fun ay =>
          let b := placeCard ww wh ax ay 340
          decide (margin ≤ b.x && b.x + b.w + margin ≤ ww &&
                  margin ≤ b.y && b.y + b.h + margin ≤ wh)))))

theorem agent_state_cube_holds : agentStateCube = true := by native_decide
theorem step_timeline_cube_holds : stepTimelineCube = true := by native_decide
theorem card_placement_cube_holds : cardPlacementCube = true := by native_decide

end Nano.SubagentTasks
