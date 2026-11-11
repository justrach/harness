import Nano.FrameSchedule
import Nano.ScrollFollow
import Nano.Tween
import Nano.StripMenu
import Nano.FooterChips
import Nano.QuestionPanel
import Nano.IosLiquidGlassScroll

open Nano

/-- Verifies all seven Harness Nano / nanoui formal kernels and prints their
enumerated cube sizes. Run with:
  `lean --run Main.lean` (inside `apps/nano/lean-proofs` with `LEAN_PATH=.`) -/
def main : IO Unit := do
  IO.println "harness-nano lean-proofs (verified kernels)"
  IO.println s!"frame_schedule  {FrameSchedule.scheduleCells}  single_pass={FrameSchedule.singlePassCells}  desktop_regressions={FrameSchedule.desktopRegressionCube}"
  IO.println s!"scroll_follow   {ScrollFollow.scrollCells}  quiescent={ScrollFollow.stationaryQuiescentCheck}  growth={ScrollFollow.growthFollowCheck}"
  IO.println s!"tween           {Tween.tweenCells}  continuous={Tween.retargetContinuityCube}  culling_sound={Tween.cullingSoundCube}"
  IO.println s!"strip_menu      {StripMenu.stripCells}  chip_conserved={StripMenu.chipConservationCube}  focus_kept={StripMenu.menuFocusPreservedCube}  split_bounded={StripMenu.splitSlotPartitionCube}"
  IO.println s!"footer_chips    {FooterChips.footerCells}  conserved={FooterChips.footerConservationCube}  monotone={FooterChips.footerMonotoneCube}  rank_order={FooterChips.footerRankOrderCube}  split_windows={FooterChips.footerSplitWindowsCube}"
  IO.println s!"ui_mode_fsm     zen_default={FrameSchedule.UiState.initial.mode == .zen}  zen_depth={FrameSchedule.hierarchyDepth (FrameSchedule.HierarchyProfile.ofMode .zen)}  dev_depth={FrameSchedule.hierarchyDepth (FrameSchedule.HierarchyProfile.ofMode .developer)}  zen_parts={FrameSchedule.movingPartsCount (FrameSchedule.HierarchyProfile.ofMode .zen)}  dev_parts={FrameSchedule.HierarchyProfile.ofMode .developer |> FrameSchedule.movingPartsCount}"
  IO.println s!"question_panel  {QuestionPanel.questionCells}  conserved={QuestionPanel.splitConservationCube}  monotone={QuestionPanel.splitMonotoneCube}  chip_bounded={QuestionPanel.chipCube}"
  IO.println s!"ios_glass_120hz {IosLiquidGlassScroll.iosGlassScrollCells}  surfaces_22={IosLiquidGlassScroll.allSurfacesValidCheck}  underlap={IosLiquidGlassScroll.underlapCubeCheck}  fling_0998={IosLiquidGlassScroll.flingConvergenceCheck}"
  IO.println s!"cells_total     {FrameSchedule.scheduleCells + ScrollFollow.scrollCells + Tween.tweenCells + StripMenu.stripCells + FooterChips.footerCells + QuestionPanel.questionCells + IosLiquidGlassScroll.iosGlassScrollCells}"
