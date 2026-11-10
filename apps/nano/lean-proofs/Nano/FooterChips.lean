/-
  Draft Composer Footer Chip Allocation Kernel (`FooterChips`).

  The footer under a new chat's composer (`apps/nano/src/view_newchat.zig`
  `footer`) draws, after the model chip, up to six controls in one 24px row:
  `Code`, `Steer`, `🖥 Run on: <computer> ⌄`, `📁 <project> ⌄`,
  `<checkout> ⌄` and `⑂ <ref> ⌄`. They were laid out at their natural widths
  inside a clipping slot, so in a split pane the trailing chips were cut
  mid-word (`N` of `New worktree`) or pushed out of reach entirely.

  Models:
  1. `footerChipWidths`: which controls keep their words, which fall back to
     their 28px glyph, and (only once even the glyphs cannot fit) which are
     left out, for a slot `room` px wide. The first layout that fits wins, in
     this order of preference:
       a. every label whole;
       b. the computer, then the follow-up switch, reduced to a glyph (the
          `freeCollapse` lowest-ranked: the tab strip names the computer
          too, and the switch's glyph already says which it is), the other
          labels whole;
       c. the remaining labels ellipsized to a shared cap no shorter than
          `minLabel`;
       d. the same with the `k` lowest-ranked controls reduced to a glyph,
          for `k = freeCollapse + 1 … rankCount`;
       e. glyphs only, leaving out the `h` lowest-ranked controls.
  2. `footerRoom`: the slot's width inside a composer `w` px wide, after the
     row's padding, the model chip, the wide row's separator and a chat note.
  3. `dockedWidth` / `modelChipMax`: the composer's and the model chip's
     widths in a pane (`view_composer.zig` `dockedWidth`, `chip`).

  Executable Zig port: `apps/nano/src/motion_rules.zig`.
-/

namespace Nano.FooterChips

/-- A footer control: `chrome` is everything but its words (insets, glyph,
gaps, chevron), `text` its words' natural width, and `rank` how soon it gives
way (lowest first). -/
structure Chip where
  chrome : Nat
  text   : Nat
  rank   : Nat
deriving DecidableEq, Repr, BEq

/-- Where a control lands: `w = 0` leaves it out, `label = 0` draws its glyph
alone, else `label` is the width its words may take. -/
structure Slot where
  w     : Nat
  label : Nat
deriving DecidableEq, Repr, BEq

/-- Two 8px insets around a 12px glyph. -/
def iconW : Nat := 28
def chipGap : Nat := 4
/-- A label is never ellipsized below this; the control drops to its glyph. -/
def minLabel : Nat := 96
def rankCount : Nat := 6
/-- Controls ranked below this give up their words before any label is
shortened. -/
def freeCollapse : Nat := 2

def place (collapse hide cap : Nat) (c : Chip) : Slot :=
  if c.rank < hide then { w := 0, label := 0 }
  else if c.rank < collapse then { w := iconW, label := 0 }
  else { w := c.chrome + Nat.min c.text cap, label := Nat.min c.text cap }

def layout (collapse hide cap : Nat) (chips : List Chip) : List Slot :=
  chips.map (place collapse hide cap)

def shown (slots : List Slot) : List Slot :=
  slots.filter (fun s => decide (s.w > 0))

/-- The drawn controls' widths and the 4px gaps between them. -/
def totalW (slots : List Slot) : Nat :=
  ((shown slots).map (fun s => s.w)).sum + ((shown slots).length - 1) * chipGap

def fits (room : Nat) (slots : List Slot) : Bool :=
  decide (totalW slots ≤ room)

def maxText (chips : List Chip) : Nat :=
  chips.foldl (fun m c => Nat.max m c.text) 0

/-- Shared label caps, widest first, down to `minLabel` (or the longest label
when none reaches it). -/
def caps (chips : List Chip) : List Nat :=
  let top := maxText chips
  let low := Nat.min minLabel top
  (List.range (top - low + 1)).map (fun i => top - i)

def candidates (chips : List Chip) : List (List Slot) :=
  (List.range freeCollapse).map (fun k => layout k 0 (maxText chips) chips)
  ++ (List.range (rankCount - freeCollapse + 1)).flatMap
    (fun i => (caps chips).map (fun cap => layout (freeCollapse + i) 0 cap chips))
  ++ (List.range (rankCount + 1)).map (fun h => layout rankCount h 0 chips)

def hiddenAll (chips : List Chip) : List Slot :=
  chips.map (fun _ => { w := 0, label := 0 })

/-- Pure width allocation for the draft footer's controls. -/
def footerChipWidths (room : Nat) (chips : List Chip) : List Slot :=
  ((candidates chips).find? (fits room)).getD (hiddenAll chips)

theorem hiddenAll_total (chips : List Chip) : totalW (hiddenAll chips) = 0 := by
  have h : shown (hiddenAll chips) = [] := by
    unfold shown hiddenAll
    induction chips with
    | nil => rfl
    | cons _ _ ih => simp
  simp [totalW, h]

/-- Theorem: for every slot width and every set of controls, what is drawn
(with its gaps) fits the slot. Nothing is cut at the composer's edge. -/
theorem never_overflows (room : Nat) (chips : List Chip) :
    totalW (footerChipWidths room chips) ≤ room := by
  unfold footerChipWidths
  cases h : (candidates chips).find? (fits room) with
  | none =>
    simp only [Option.getD_none]
    rw [hiddenAll_total]
    exact Nat.zero_le _
  | some l =>
    have hfit := List.find?_some h
    simpa [fits] using hfit

/-- The row's inner gap: 6px once the composer is 540px wide, else 4px. -/
def rowGap (w : Nat) : Nat := if w ≥ 540 then 6 else 4

/-- What precedes the slot: the model chip and its gap, and in a wide row the
3px separator and its gap. -/
def footerLead (w modelW : Nat) : Nat :=
  modelW + rowGap w + (if w ≥ 540 then 3 + rowGap w else 0)

/-- What follows the slot: a plain chat's note and its gap. -/
def footerTail (w noteW : Nat) : Nat :=
  if noteW = 0 then 0 else rowGap w + noteW

/-- The slot's width in a composer `w` px wide (two 10px insets). -/
def footerRoom (w modelW noteW : Nat) : Nat :=
  w - Nat.min w (20 + footerLead w modelW + footerTail w noteW)

/-- Theorem: at every composer width (any split) the whole footer row, insets
and model chip included, ends inside the composer whenever the model chip
itself does. -/
theorem footer_row_within_composer (w modelW noteW : Nat) (chips : List Chip)
    (h : 20 + footerLead w modelW + footerTail w noteW ≤ w) :
    20 + footerLead w modelW
      + totalW (footerChipWidths (footerRoom w modelW noteW) chips)
      + footerTail w noteW ≤ w := by
  have hr : footerRoom w modelW noteW
      = w - (20 + footerLead w modelW + footerTail w noteW) := by
    unfold footerRoom
    have hm : Nat.min w (20 + footerLead w modelW + footerTail w noteW)
        = 20 + footerLead w modelW + footerTail w noteW := Nat.min_eq_right h
    rw [hm]
  have hb := never_overflows (footerRoom w modelW noteW) chips
  rw [hr] at hb ⊢
  omega

/-- `view_composer.zig` `dockedWidth`. -/
def dockedWidth (pane column : Nat) : Nat :=
  Nat.min (column + 32) pane - 32

/-- `view_composer.zig` `chip`: the model chip's width limit in a pane. -/
def modelChipMax (pane : Nat) : Nat :=
  Nat.min 248 (Nat.max 80 (pane - 132))

/-- A pane of an `n`-way split of the chat area beside a `sidebarW` sidebar. -/
def splitPaneWidth (windowW sidebarW n : Nat) : Nat :=
  (windowW - sidebarW) / n

/-! The controls as measured at 12px (`tests_ui_desktop_sidebar_composer.zig`). -/

def mode : Chip := { chrome := 34, text := 30, rank := 4 }
def follow : Chip := { chrome := 33, text := 33, rank := 1 }
def computer : Chip := { chrome := 52, text := 98, rank := 0 }
def project : Chip := { chrome := 52, text := 45, rank := 2 }
def checkout : Chip := { chrome := 52, text := 79, rank := 3 }
def branch : Chip := { chrome := 52, text := 60, rank := 5 }
/-- Labels are measured up to `280 - 52` (the chip's 280px limit). -/
def longProject : Chip := { chrome := 52, text := 228, rank := 2 }
def longBranch : Chip := { chrome := 52, text := 228, rank := 5 }

/-- `Code  Steer  Run on: This Mac ⌄  harness ⌄  New worktree ⌄  From main ⌄`. -/
def screenshotChips : List Chip := [mode, follow, computer, project, checkout, branch]

def chipSets : List (List Chip) :=
  [ [mode, computer]
  , [mode, computer, project]
  , [mode, follow, computer, project]
  , [mode, computer, project, checkout, branch]
  , screenshotChips
  , [mode, follow, computer, longProject, checkout, longBranch] ]

def rooms : List Nat := List.range 801

def footerCells : Nat := chipSets.length * rooms.length

theorem footer_cube : footerCells = 4806 := by native_decide

def naturalSlots (chips : List Chip) : List Slot :=
  chips.map (fun c => { w := c.chrome + c.text, label := c.text })

def iconSlots (chips : List Chip) : List Slot :=
  chips.map (fun _ => { w := iconW, label := 0 })

def shownCount (slots : List Slot) : Nat := (shown slots).length

def labelledCount (slots : List Slot) : Nat :=
  (slots.filter (fun s => decide (s.label > 0))).length

/-- Theorem: in the reported split pane (the slot ends ~415px after the model
chip, where `New worktree` was cut to `N` and the ref chip was unreachable),
all six controls are drawn whole: `Code`, the checkout and the ref keep their
words (and the pickers their chevrons), `Steer`, the computer and the project
their glyphs, in 411px. -/
theorem screenshot_split_pane_keeps_every_control :
    footerChipWidths 415 screenshotChips =
      [ { w := 64, label := 30 }, { w := 28, label := 0 }, { w := 28, label := 0 }
      , { w := 28, label := 0 }, { w := 131, label := 79 }, { w := 112, label := 60 } ] ∧
    totalW (footerChipWidths 415 screenshotChips) = 411 := by
  native_decide

/-- Theorem: a long ref keeps every word beside a long computer name. The
computer gives up its words before any label is shortened
(`bottom-docked checkout and ref popovers…` in `tests_ui.zig`: a 622px slot,
`Run on: Unknown device` and `From feature/popover-upward`). -/
theorem long_ref_is_whole_before_the_computer_keeps_its_words :
    footerChipWidths 622
        [mode, { chrome := 52, text := 140, rank := 0 }, project, checkout,
          { chrome := 52, text := 170, rank := 5 }] =
      [ { w := 64, label := 30 }, { w := 28, label := 0 }, { w := 97, label := 45 }
      , { w := 131, label := 79 }, { w := 222, label := 170 } ] := by
  native_decide

/-- Exhaustive check over every slot width 0…800 and each set of controls:
1. the drawn controls fit the slot, one slot per control;
2. when the natural widths fit, nothing is shortened;
3. a control is left out, a bare glyph, or its whole chrome plus a label that
   is complete or at least `minLabel` wide. Never a partly cut control;
4. while the glyphs alone fit, no control is left out. -/
def footerConservationCube : Bool :=
  chipSets.all (fun chips =>
    rooms.all (fun room =>
      let out := footerChipWidths room chips
      totalW out ≤ room &&
      out.length == chips.length &&
      (if totalW (naturalSlots chips) ≤ room then out == naturalSlots chips else true) &&
      (chips.zip out).all (fun (c, s) =>
        s.w == 0 ||
        (s.w == iconW && s.label == 0) ||
        (s.w == c.chrome + s.label && s.label ≤ c.text &&
          (s.label == c.text || s.label ≥ minLabel))) &&
      (if totalW (iconSlots chips) ≤ room then shownCount out == chips.length else true)))

theorem footer_conservation_holds : footerConservationCube = true := by
  native_decide

/-- Widening the slot by a pixel never takes a control away, and never takes
the words from more controls. (A long label may shorten toward `minLabel` so
that another control gets its words back.) -/
def footerMonotoneCube : Bool :=
  chipSets.all (fun chips =>
    rooms.all (fun room =>
      let a := footerChipWidths room chips
      let b := footerChipWidths (room + 1) chips
      shownCount a ≤ shownCount b && labelledCount a ≤ labelledCount b))

theorem footer_widening_never_drops_a_control : footerMonotoneCube = true := by
  native_decide

/-- Controls give way in rank order: one left out or reduced to its glyph
means every lower-ranked control was too. -/
def footerRankOrderCube : Bool :=
  chipSets.all (fun chips =>
    rooms.all (fun room =>
      let cells := chips.zip (footerChipWidths room chips)
      cells.all (fun (c, s) =>
        cells.all (fun (d, t) =>
          if d.rank < c.rank then
            (if s.w == 0 then t.w == 0 else true) &&
            (if s.label == 0 then t.label == 0 else true)
          else true))))

theorem footer_controls_yield_in_rank_order : footerRankOrderCube = true := by
  native_decide

/-- Split windows: window widths, an open (244px) or closed sidebar, one to
three panes side by side, and model chips from a bare glyph to the 248px
limit. In every pane the footer row ends inside the composer, and once the
slot has the glyphs' 188px every control stays reachable. -/
def footerSplitWindowsCube : Bool :=
  [1024, 1200, 1280, 1440, 1512, 1728, 1920].all (fun windowW =>
    [0, 244].all (fun sidebarW =>
      [1, 2, 3].all (fun n =>
        [34, 79, 120, 160, 200, 248].all (fun modelNatural =>
          chipSets.all (fun chips =>
            let pane := splitPaneWidth windowW sidebarW n
            let w := dockedWidth pane 736
            let modelW := Nat.min modelNatural (modelChipMax pane)
            let room := footerRoom w modelW 0
            let out := footerChipWidths room chips
            20 + footerLead w modelW + totalW out ≤ w &&
            (if totalW (iconSlots chips) ≤ room then shownCount out == chips.length else true))))))

theorem footer_split_windows_hold : footerSplitWindowsCube = true := by
  native_decide

/-- Theorem: a 1440px window split in two beside the sidebar (598px panes, a
566px composer, a 160px model chip) leaves the slot 371px: all six controls
are drawn, `Code` and the ref with their words. Split in three with the
sidebar closed (480px panes, a 264px slot) all six are still there as glyphs. -/
theorem split_1440_keeps_every_control :
    footerRoom (dockedWidth (splitPaneWidth 1440 244 2) 736) 160 0 = 371 ∧
    shownCount (footerChipWidths 371 screenshotChips) = 6 ∧
    labelledCount (footerChipWidths 371 screenshotChips) = 2 ∧
    footerRoom (dockedWidth (splitPaneWidth 1440 0 3) 736) 160 0 = 264 ∧
    shownCount (footerChipWidths 264 screenshotChips) = 6 := by
  native_decide

end Nano.FooterChips
