/-
  HarnessProofs.Chat2Sync

  Formal kernel & proofs for the Zig engine's `chat2` sync protocol
  (`apps/nano/src/chat2_wire.zig`, `apps/nano/src/chat2_client.zig`,
  and `protocol/chat2-vectors.json`).
-/

namespace HarnessProofs.Chat2Sync

structure StateHeader where
  headSeq        : Nat := 0
  seqFloor       : Nat := 0
  checkpointSeq  : Nat := 0
  checkpointSize : Nat := 0
deriving DecidableEq, Repr, BEq

inductive CatchUpPlan where
  | rowsOnly (after : Nat)
  | checkpointThenRows (after : Nat)
deriving DecidableEq, Repr, BEq

/-- `chat2_wire.planCatchUp`: decide the catch-up path from the `state` header. -/
def planCatchUp (cursor : Nat) (state : StateHeader) (frontierContained : Bool) : CatchUpPlan :=
  let cur := if cursor > state.headSeq then 0 else cursor
  if state.checkpointSize == 0 then
    .rowsOnly cur
  else if frontierContained then
    .rowsOnly (Nat.max cur state.checkpointSeq)
  else
    .checkpointThenRows state.checkpointSeq

/-- `chat2_wire.nextRowCursor`: contiguity rule for each incoming row `seq`. -/
def nextRowCursor (cursor : Nat) (seq : Nat) : Option Nat :=
  if seq ≤ cursor + 1 then
    some (Nat.max cursor seq)
  else
    none

/-! ### Formal Theorems for `nextRowCursor` -/

theorem nextRowCursor_gap_rejected (cursor seq : Nat) (h : ¬ seq ≤ cursor + 1) :
    nextRowCursor cursor seq = none := by
  unfold nextRowCursor
  simp [h]

theorem nextRowCursor_contiguous (cursor seq cur' : Nat)
    (h : nextRowCursor cursor seq = some cur') :
    seq ≤ cursor + 1 := by
  unfold nextRowCursor at h
  split at h
  · assumption
  · contradiction

theorem nextRowCursor_monotone (cursor seq cur' : Nat)
    (h : nextRowCursor cursor seq = some cur') :
    cursor ≤ cur' := by
  unfold nextRowCursor at h
  split at h
  · injection h with h_eq
    rw [← h_eq]
    exact Nat.le_max_left cursor seq
  · contradiction

theorem nextRowCursor_idempotent_duplicate (cursor seq : Nat) (h : seq ≤ cursor) :
    nextRowCursor cursor seq = some cursor := by
  unfold nextRowCursor
  have h1 : seq ≤ cursor + 1 := Nat.le_trans h (Nat.le_succ cursor)
  simp [h1, Nat.max_eq_left h]

theorem nextRowCursor_advance_by_one (cursor : Nat) :
    nextRowCursor cursor (cursor + 1) = some (cursor + 1) := by
  unfold nextRowCursor
  have h1 : cursor ≤ cursor + 1 := Nat.le_succ cursor
  simp [Nat.max_eq_right h1]

/-! ### Formal Theorems for `planCatchUp` -/

theorem planCatchUp_no_checkpoint (cursor : Nat) (state : StateHeader) (fc : Bool)
    (h : state.checkpointSize = 0) :
    planCatchUp cursor state fc = .rowsOnly (if cursor > state.headSeq then 0 else cursor) := by
  unfold planCatchUp
  simp [h]

theorem planCatchUp_frontier_contained_skips_checkpoint (cursor : Nat) (state : StateHeader)
    (h : state.checkpointSize ≠ 0) :
    planCatchUp cursor state true =
      .rowsOnly (Nat.max (if cursor > state.headSeq then 0 else cursor) state.checkpointSeq) := by
  unfold planCatchUp
  simp [h]

theorem planCatchUp_missing_frontier_fetches_checkpoint (cursor : Nat) (state : StateHeader)
    (h : state.checkpointSize ≠ 0) :
    planCatchUp cursor state false = .checkpointThenRows state.checkpointSeq := by
  unfold planCatchUp
  simp [h]

/-! ### Finite State Cube & Vector Verification (`protocol/chat2-vectors.json`) -/

def sampleCursors : List Nat := [0, 3, 5, 10, 15]
def sampleStates : List StateHeader := [
  { headSeq := 0, seqFloor := 0, checkpointSeq := 0, checkpointSize := 0 },
  { headSeq := 10, seqFloor := 1, checkpointSeq := 0, checkpointSize := 0 },
  { headSeq := 10, seqFloor := 1, checkpointSeq := 5, checkpointSize := 1024 }
]

def allCatchUpCells : List CatchUpPlan :=
  Id.run do
    let mut acc : List CatchUpPlan := []
    for c in sampleCursors do
      for s in sampleStates do
        for fc in [false, true] do
          acc := acc ++ [planCatchUp c s fc]
    return acc

def catchUpCellCount : Nat := allCatchUpCells.length

theorem catchup_cube_size : catchUpCellCount = 30 := by native_decide

-- Exact vectors from `protocol/chat2-vectors.json`
example : nextRowCursor 0 1 = some 1 := by native_decide
example : nextRowCursor 5 5 = some 5 := by native_decide
example : nextRowCursor 5 3 = some 5 := by native_decide
example : nextRowCursor 5 6 = some 6 := by native_decide
example : nextRowCursor 5 7 = none := by native_decide
example : planCatchUp 0 { headSeq := 10, checkpointSeq := 5, checkpointSize := 512 } false = .checkpointThenRows 5 := by native_decide
example : planCatchUp 3 { headSeq := 10, checkpointSeq := 5, checkpointSize := 512 } true = .rowsOnly 5 := by native_decide
example : planCatchUp 7 { headSeq := 10, checkpointSeq := 5, checkpointSize := 512 } true = .rowsOnly 7 := by native_decide
example : planCatchUp 99 { headSeq := 10, checkpointSeq := 0, checkpointSize := 0 } false = .rowsOnly 0 := by native_decide

/-- Apply a list of row sequence numbers using `nextRowCursor`. -/
def applyRows (cursor : Nat) : List Nat → Option Nat
  | []      => some cursor
  | s :: ss =>
    match nextRowCursor cursor s with
    | some c' => applyRows c' ss
    | none    => none

/-- Simulate a machine executing a `CatchUpPlan` followed by tail rows `(after+1 .. headSeq)`. -/
def executeCatchUp (cursor : Nat) (state : StateHeader) (fc : Bool) (tailRows : List Nat) : Option Nat :=
  match planCatchUp cursor state fc with
  | .checkpointThenRows after => applyRows after (tailRows.filter (fun s => s > after))
  | .rowsOnly after           => applyRows (Nat.max cursor after) (tailRows.filter (fun s => s > after))

/-- Theorem: Machine A (online from seq 0 receiving [1, 2]), Machine B (caught up at checkpoint 1,
receiving tail [2]), and Machine C (joining late at cursor 0 with checkpoint 1 + tail [1, 2])
all converge to the exact same cursor `some 2`! -/
theorem three_machine_catchup_converges :
    let state : StateHeader := { headSeq := 2, seqFloor := 1, checkpointSeq := 1, checkpointSize := 256 }
    let machineA := applyRows 0 [1, 2]
    let machineB := executeCatchUp 1 state true [1, 2]
    let machineC := executeCatchUp 0 state false [1, 2]
    machineA = some 2 ∧ machineB = some 2 ∧ machineC = some 2 := by
  native_decide

end HarnessProofs.Chat2Sync
