/-
  Scroll-Follow & Stick-End Quiescence Kernel (`ScrollFollow`).

  Models `nanoui/src/ui/layout.zig`'s `follow_end` scroll clamping and
  `apps/nano/src/view_transcript.zig`'s `stick_end` + `recoverBlank`.

  Proves why a `floatMax` sentinel triggers spurious `scroll_moved` (120Hz
  display link) + `animating = true` + `recoverBlank` rebuilds on every
  tab/pane switch, and proves that `stickEnd(knownMax)` is both:
  1. Quiescent (`scroll_moved = false`, `animating = false`, `rebuild = false`)
     when switching to a stationary transcript (`newMax = max`), and
  2. Responsive (`want = newMax`) when a newly sent message or streaming reply
     increases `newMax > oldMax`.

  Executable Zig port: `apps/nano/src/motion_rules.zig`.
-/

namespace Nano.ScrollFollow

structure ScrollState where
  scroll : Nat
  seen   : Option Nat
  max    : Option Nat
  follow : Bool
deriving DecidableEq, Repr, BEq

structure ArrangeOutcome where
  state       : ScrollState
  want        : Nat
  scrollMoved : Bool
  animating   : Bool
  blankRebuild : Bool
deriving DecidableEq, Repr, BEq

def sentinel : Nat := 1000000

/-- Legacy `stick_end`: writes `sentinel` into `scroll` without updating
`follow` or `seen`. -/
def legacyStickEnd (s : ScrollState) : ScrollState :=
  { s with scroll := sentinel }

/-- Verified `stick_end`: sets `follow = true` and aligns `scroll` and `seen`
to `s.max.getD 0`. -/
def verifiedStickEnd (s : ScrollState) : ScrollState :=
  let target := s.max.getD 0
  { scroll := target, seen := some target, max := s.max, follow := true }

/-- `recoverBlank` runs before `layout.arrange` clamps `scroll`. If `scroll > max + 1`,
it considers the viewport parked in blank padding and sets `changed = true`. -/
def recoverBlankTriggers (justStuck : Bool) (s : ScrollState) : Bool :=
  if justStuck then false
  else match s.max with
  | none   => false
  | some m => decide (s.scroll > m + 1)

/-- Exact integer model of `nanoui/src/ui/layout.zig` lines 185–201. -/
def arrange (justStuck : Bool) (s : ScrollState) (newMax : Nat) : ArrangeOutcome :=
  let blank := recoverBlankTriggers justStuck s
  let cur := s.scroll
  let want := if s.follow then newMax else Nat.min cur newMax
  let nextFollow := decide (newMax <= want + 1)
  let moved := match s.seen with
    | none      => false
    | some seen =>
      let diffSeen := if cur >= seen then cur - seen else seen - cur
      let diffMax  := if cur >= newMax then cur - newMax else newMax - cur
      decide (diffSeen > 0) && !(s.follow && decide (diffMax <= 1))
  let diffWant := if cur >= want then cur - want else want - cur
  let anim := decide (diffWant > 0)
  { state := { scroll := want, seen := some want, max := some newMax, follow := nextFollow }
  , want := want
  , scrollMoved := moved
  , animating := anim
  , blankRebuild := blank }

def maxValues : List Nat := [0, 120, 480, 1600]

def allCells : List (ScrollState × Nat) :=
  Id.run do
    let mut acc : List (ScrollState × Nat) := []
    for m in [none, some 0, some 120, some 480, some 1600] do
      for sc in [0, 60, 120, 480, 1600] do
        for fl in [false, true] do
          for nm in maxValues do
            acc := acc ++ [({ scroll := sc, seen := m, max := m, follow := fl }, nm)]
    return acc

def scrollCells : Nat := allCells.length

theorem scroll_cube : scrollCells = 200 := by native_decide

/-- Legacy `stick_end` on any already-laid-out transcript triggers `scrollMoved`,
`animating`, and `blankRebuild` simultaneously. -/
theorem legacy_sentinel_triggers_spurious_work :
    let s : ScrollState := { scroll := 480, seen := some 480, max := some 480, follow := true }
    let out := arrange false (legacyStickEnd s) 480
    out.scrollMoved = true ∧ out.animating = true ∧ out.blankRebuild = true := by
  native_decide

/-- Verified `stick_end` on a stationary transcript (`newMax = m`) is 100%
quiescent across all states in the cube: zero `scrollMoved`, zero `animating`,
zero `blankRebuild`, and `want = m`. -/
def stationaryQuiescentCheck : Bool :=
  allCells.all (fun (s, nm) =>
    match s.max with
    | none => true
    | some m =>
      if m == nm then
        let out := arrange true (verifiedStickEnd s) nm
        out.want == nm && !out.scrollMoved && !out.animating && !out.blankRebuild
      else true)

theorem stick_end_stationary_quiescent : stationaryQuiescentCheck = true := by
  native_decide

/-- Verified `stick_end` when a new message grows the transcript (`nm > m`)
always snaps `want` to `nm` and keeps `follow = true`, even if the reader had
previously scrolled far up (`follow = false`, `scroll = 0`). -/
def growthFollowCheck : Bool :=
  allCells.all (fun (s, nm) =>
    let out := arrange true (verifiedStickEnd s) nm
    out.want == nm && out.state.follow == true && !out.blankRebuild)

theorem stick_end_follows_growth : growthFollowCheck = true := by
  native_decide

end Nano.ScrollFollow
