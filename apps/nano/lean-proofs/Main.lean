import Nano.FrameSchedule
import Nano.ScrollFollow
import Nano.Tween
import Nano.StripMenu

open Nano

/-- Verifies all four Harness Nano / nanoui formal kernels and prints their
enumerated cube sizes. Run with:
  `lean --run Main.lean` (inside `apps/nano/lean-proofs` with `LEAN_PATH=.`) -/
def main : IO Unit := do
  IO.println "harness-nano lean-proofs (verified kernels)"
  IO.println s!"frame_schedule  {FrameSchedule.scheduleCells}  single_pass={FrameSchedule.singlePassCells}"
  IO.println s!"scroll_follow   {ScrollFollow.scrollCells}  quiescent={ScrollFollow.stationaryQuiescentCheck}  growth={ScrollFollow.growthFollowCheck}"
  IO.println s!"tween           {Tween.tweenCells}  continuous={Tween.retargetContinuityCube}  culling_sound={Tween.cullingSoundCube}"
  IO.println s!"strip_menu      {StripMenu.stripCells}  chip_conserved={StripMenu.chipConservationCube}  focus_kept={StripMenu.menuFocusPreservedCube}"
  IO.println s!"cells_total     {FrameSchedule.scheduleCells + ScrollFollow.scrollCells + Tween.tweenCells + StripMenu.stripCells}"
