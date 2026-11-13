/-
  Agent Question Panel & Transcript Chip Kernel (`QuestionPanel`).

  An agent's question takes the composer's place under a chat
  (`apps/nano/src/view_question.zig` `panel`): a header, the question as
  Markdown, numbered options, an answer box and its buttons. The panel was as
  tall as its content, so a long question in a split or short pane pushed the
  options, the answer box and Submit below the pane's edge, out of reach. Its
  transcript chip (`chip`) gave the question a fixed 420px, so in a narrow pane
  the chip ran past the column and lost `Waiting for you`.

  Models:
  1. `panelMax`: the height the panel may take in the room its pane gives the
     composer dock, less what the dock holds around it (`around`: its foot
     padding, the queue tray, dictation status) and a gap under the bar above.
  2. `split`: how the height left by the panel's pinned parts (`budget`) is
     shared between the question and the options, each scrolling in what it
     gets. The options take what they need while the question keeps `keep`
     (120px, or half of a small budget); the question takes the rest.
  3. `chipFit`: the width the chip's question may take in a column `col` wide,
     and whether `Waiting for you` is drawn after it.

  Executable Zig port: `apps/nano/src/motion_rules.zig`.
-/

namespace Nano.QuestionPanel

/-- What the question keeps before the options are shortened. -/
def floorH : Nat := 120
/-- The gap between the panel and the bar over the conversation. -/
def topGap : Nat := 12

/-- The panel's height limit in a dock given `room`, holding `around` besides
the panel. -/
def panelMax (room around : Nat) : Nat := room - around - topGap

structure Split where
  question : Nat
  options  : Nat
deriving DecidableEq, Repr, BEq

def keep (budget : Nat) : Nat := min floorH (budget / 2)

/-- The heights the question (`q` tall) and the options (`o` tall) get of
`budget`. -/
def split (budget q o : Nat) : Split :=
  let opts := min o (budget - min q (keep budget))
  { question := min q (budget - opts), options := opts }

/-- Theorem: the two never take more than the budget, whatever their heights. -/
theorem split_within_budget (b q o : Nat) :
    (split b q o).question + (split b q o).options ≤ b := by
  simp only [split, keep, floorH]
  omega

/-- Theorem: when both fit, neither is shortened. -/
theorem split_whole_when_fits (b q o : Nat) (h : q + o ≤ b) :
    split b q o = { question := q, options := o } := by
  simp only [split, keep, floorH, Split.mk.injEq]
  omega

/-- Theorem: the question keeps its floor (or all of itself, when shorter). -/
theorem split_question_keeps_floor (b q o : Nat) :
    min q (keep b) ≤ (split b q o).question := by
  simp only [split, keep, floorH]
  omega

/-- Theorem: the options are whole unless the question is already down to its
floor. A long question gives way first. -/
theorem split_question_yields_first (b q o : Nat)
    (h : (split b q o).options < o) : (split b q o).question ≤ keep b := by
  simp only [split, keep, floorH] at h ⊢
  omega

/-- Theorem: with `pinned` (the header, the answer box and the buttons) inside
the panel's limit, and room for what the dock holds around the panel, the
dock's contents end inside the room the pane gives it: the options, the
answer box and Submit are never below the pane's edge. -/
theorem panel_ends_inside_pane (room around pinned q o : Nat)
    (ha : around ≤ room) (h : pinned ≤ panelMax room around) :
    around + (pinned
      + (split (panelMax room around - pinned) q o).question
      + (split (panelMax room around - pinned) q o).options) ≤ room := by
  have hs := split_within_budget (panelMax room around - pinned) q o
  simp only [panelMax, topGap] at h hs ⊢
  omega

/-- The reported pane: 700px left for a 1400px question and three options
(150px). The options are whole and the question scrolls in the other 550px. -/
theorem screenshot_question_scrolls_over_whole_options :
    split 700 1400 150 = { question := 550, options := 150 } := by
  native_decide

def budgets : List Nat := List.range 601
def questionHeights : List Nat := [0, 40, 120, 300, 900]
def optionHeights : List Nat := [0, 60, 150, 400, 900]

def questionCells : Nat :=
  budgets.length * questionHeights.length * optionHeights.length

theorem question_cube : questionCells = 15025 := by native_decide

/-- Exhaustive check over every budget 0…600 and each pair of heights: the
two fit the budget, are whole when they can be, and the question keeps its
floor. -/
def splitConservationCube : Bool :=
  budgets.all (fun b =>
    questionHeights.all (fun q =>
      optionHeights.all (fun o =>
        let s := split b q o
        s.question + s.options ≤ b &&
        s.question ≤ q && s.options ≤ o &&
        (if q + o ≤ b then s.question == q && s.options == o else true) &&
        min q (keep b) ≤ s.question &&
        (if s.options < o then s.question ≤ keep b else true))))

theorem split_conservation_holds : splitConservationCube = true := by
  native_decide

/-- A taller budget never takes height from either. -/
def splitMonotoneCube : Bool :=
  budgets.all (fun b =>
    questionHeights.all (fun q =>
      optionHeights.all (fun o =>
        (split b q o).question ≤ (split (b + 1) q o).question &&
        (split b q o).options ≤ (split (b + 1) q o).options)))

theorem split_grows_with_the_pane : splitMonotoneCube = true := by
  native_decide

/-- The widest the chip's question is drawn (GPUI's 420px label). -/
def chipCap : Nat := 420
/-- `Waiting for you` is drawn while the question keeps this much (or all of
itself). -/
def chipMinLabel : Nat := 96

structure Chip where
  label   : Nat
  waiting : Bool
deriving DecidableEq, Repr, BEq

/-- The chip in a column `col` wide: `lead` is everything but the question
(insets, tile, `Question` and their gaps), `qw` the question's width, `ww`
`Waiting for you` with its gap (0 once answered). -/
def chipFit (col lead qw ww : Nat) : Chip :=
  let room := col - lead
  if ww > 0 ∧ ww + min qw chipMinLabel ≤ room then
    { label := min chipCap (room - ww), waiting := true }
  else
    { label := min chipCap room, waiting := false }

def chipWidth (lead qw ww : Nat) (c : Chip) : Nat :=
  lead + min qw c.label + (if c.waiting then ww else 0)

/-- Theorem: the chip ends inside its column at every width. -/
theorem chip_within_column (col lead qw ww : Nat) (h : lead ≤ col) :
    chipWidth lead qw ww (chipFit col lead qw ww) ≤ col := by
  unfold chipWidth chipFit
  simp only [chipCap, chipMinLabel]
  by_cases hc : ww > 0 ∧ ww + min qw 96 ≤ col - lead
  · simp only [hc, and_self, ite_true]
    omega
  · simp only [hc, ite_false, Bool.false_eq_true]
    omega

/-- The reported pane: a 520px column, a 700px question. `Waiting for you`
(98px with its gap) stays, and the question fades at 314px. -/
theorem screenshot_chip_keeps_waiting :
    chipFit 520 108 700 98 = { label := 314, waiting := true } ∧
    chipWidth 108 700 98 (chipFit 520 108 700 98) = 520 := by
  native_decide

def chipCube : Bool :=
  (List.range 801).all (fun col =>
    [0, 60, 200, 700].all (fun qw =>
      [0, 98].all (fun ww =>
        let c := chipFit col 108 qw ww
        (if 108 ≤ col then chipWidth 108 qw ww c ≤ col else true) &&
        c.label ≤ chipCap &&
        (if c.waiting then min qw chipMinLabel ≤ c.label else true))))

theorem chip_cube_holds : chipCube = true := by native_decide

end Nano.QuestionPanel
