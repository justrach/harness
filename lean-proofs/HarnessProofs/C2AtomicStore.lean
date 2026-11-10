/-
  HarnessProofs.C2AtomicStore

  Formal kernel & proofs for `DocsStore` (`apps/nano/src/docs_store.zig`):
  1. C2 Rule (`docs/chat2-sync.md`): snapshot bytes (`snapshotSeq`) and
     `cursor` always update atomically together (`c2Invariant`).
  2. Mark-before-execute command idempotence (`markCommandProcessed`):
     replayed `QueueCommand` messages never execute twice.
-/

namespace HarnessProofs.C2AtomicStore

structure StoreState where
  snapshotSeq    : Nat := 0
  cursor         : Nat := 0
  cursorVerified : Bool := true
  processedCmds  : List Nat := []
  execCount      : Nat := 0
deriving DecidableEq, Repr, BEq

def c2Invariant (s : StoreState) : Bool :=
  (s.snapshotSeq == s.cursor) && s.cursorVerified

/-- `DocsStore.saveSnapshotWithCursor`: atomic update of snapshot + cursor. -/
def saveSnapshotWithCursor (s : StoreState) (seq : Nat) : StoreState :=
  { s with snapshotSeq := seq, cursor := seq, cursorVerified := true }

/-- `DocsStore.markCommandProcessed`: mark-before-execute command ledger. -/
def executeCommandOnce (s : StoreState) (cmdId : Nat) : StoreState :=
  if s.processedCmds.contains cmdId then
    s
  else
    { s with processedCmds := cmdId :: s.processedCmds, execCount := s.execCount + 1 }

theorem c2_init_holds : c2Invariant {} = true := by native_decide

theorem c2_preserved_by_save (s : StoreState) (seq : Nat) :
    c2Invariant (saveSnapshotWithCursor s seq) = true := by
  unfold c2Invariant saveSnapshotWithCursor
  simp

theorem c2_preserved_by_command (s : StoreState) (cmdId : Nat)
    (h : c2Invariant s = true) :
    c2Invariant (executeCommandOnce s cmdId) = true := by
  unfold executeCommandOnce
  split
  · exact h
  · unfold c2Invariant at *
    exact h

theorem command_replay_is_noop (s : StoreState) (cmdId : Nat) :
    let s1 := executeCommandOnce s cmdId
    let s2 := executeCommandOnce s1 cmdId
    s2.execCount = s1.execCount := by
  dsimp
  unfold executeCommandOnce
  split
  · simp
  · simp

end HarnessProofs.C2AtomicStore
