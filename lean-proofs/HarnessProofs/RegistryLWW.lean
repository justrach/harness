/-
  HarnessProofs.RegistryLWW

  Formal kernel & convergence proofs for the Zig engine's `reg1` per-field
  Last-Writer-Wins (LWW) CRDT (`apps/nano/src/registry_sync.zig`).
-/

namespace HarnessProofs.RegistryLWW

structure Stamp where
  ts       : Nat
  deviceId : Nat
deriving DecidableEq, Repr, BEq

structure Cell where
  val   : Nat
  stamp : Stamp
deriving DecidableEq, Repr, BEq

/-- `Stamp.newerOrEqual`: total lexicographic order `(ts, deviceId)`. -/
def newerOrEqual (a b : Stamp) : Bool :=
  if a.ts != b.ts then
    a.ts > b.ts
  else
    a.deviceId ≥ b.deviceId

/-- Per-field LWW merge (`RegistryDoc.setField` in `registry_sync.zig`). -/
def mergeCell (a b : Cell) : Cell :=
  if newerOrEqual a.stamp b.stamp then a else b

theorem newerOrEqual_refl (s : Stamp) : newerOrEqual s s = true := by
  unfold newerOrEqual
  simp

theorem mergeCell_idem (c : Cell) : mergeCell c c = c := by
  unfold mergeCell
  rw [newerOrEqual_refl]
  rfl

/-- Tombstone gate (`RegistryDoc.setField` / `deleteRow`): a row tombstone at
`tomb` blocks any field write `incoming` unless `incoming` is strictly newer. -/
def tombstoneBlocks (tomb incoming : Stamp) : Bool :=
  newerOrEqual tomb incoming

theorem tombstone_blocks_older_ts (tomb incoming : Stamp) (h : tomb.ts > incoming.ts) :
    tombstoneBlocks tomb incoming = true := by
  unfold tombstoneBlocks newerOrEqual
  have hne : (tomb.ts != incoming.ts) = true := by
    simp [Nat.ne_of_gt h]
  simp [hne, h]

/-! ### 3-Machine (`devA=1, devB=2, devC=3`) Convergence Cube -/

def sampleCells : List Cell :=
  Id.run do
    let mut acc : List Cell := []
    for ts in [10, 20, 30] do
      for dev in [1, 2, 3] do
        acc := acc ++ [{ val := ts * 10 + dev, stamp := { ts := ts, deviceId := dev } }]
    return acc

def lwwPairsCommutative : Bool :=
  Id.run do
    for a in sampleCells do
      for b in sampleCells do
        if mergeCell a b != mergeCell b a then
          return false
    return true

def lwwTriplesAssociative : Bool :=
  Id.run do
    for a in sampleCells do
      for b in sampleCells do
        for c in sampleCells do
          if mergeCell (mergeCell a b) c != mergeCell a (mergeCell b c) then
            return false
    return true

def lwwTriplesCount : Nat := sampleCells.length * sampleCells.length * sampleCells.length

theorem lww_cube_size : lwwTriplesCount = 729 := by native_decide
theorem lww_3machine_commutative : lwwPairsCommutative = true := by native_decide
theorem lww_3machine_associative : lwwTriplesAssociative = true := by native_decide

end HarnessProofs.RegistryLWW
