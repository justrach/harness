# Cmd+B grouped sidebar preparation

The sidebar already virtualized offscreen session rows and group headers.
However, each animation frame discovered groups with a linear key search and
rescanned all chats to count each group. Project validation also searched all
projects for each chat. With many project groups, preparation was quadratic
even though the rendered UI tree stayed small.

## Change

`sidebar_groups.zig` builds a frame-local ordered membership index in one pass.
Counts and heights are accumulated once; rendering visits only a visible
group's members. Session keyboard navigation uses the same membership and
ordering rules. Project existence checks use a frame-local hash set for larger
project lists. No data is retained across frames, so live updates, filters and
disclosures do not need new invalidation or lifecycle handling.

The existing viewport spacers, motion curve, disclosure animation, clipping,
selection, focus, drag behavior and stable UI keys remain unchanged. Project
order follows first occurrence; device order promotes the current device;
attention groups still come first.

## Reproduction and measurement

`Cmd+B grouped sidebar frame work stays near the viewport` drives the real
shortcut and production shell in both directions at 120 Hz simulated time.
It compares 8 synthetic projects with 1,024 projects, one chat per project.
The original regression failed before the fix and passes afterward. Its
stable contract bounds UI-node growth; the 8-versus-1,024 CPU timings are
reported diagnostically, since even linear indexing legitimately costs more
for a larger input and runner scheduling can skew a narrow ratio.

`Cmd+B group indexing avoids the former repeated full-list scans` separately
compares the former nested scan with the production index on the **same**
4,096-group workload. It verifies identical membership counts and requires at
least a generous 2× speedup, using the best of three trials to avoid treating
a scheduler pause as algorithmic work. Neither check asserts a machine-specific
FPS.

ReleaseSafe, native offscreen tester, 32 sampled frames per fixture:

| Fixture | Before | After | Peak nodes before / after |
| --- | ---: | ---: | ---: |
| 8 projects | 0.07 ms | 0.07 ms | 319 / 319 |
| 1,024 projects | 4.35 ms | 0.19 ms | 363 / 363 |

These are average CPU build/layout measurements, not GPU presentation or
end-to-end 120 FPS measurements. Very large chat, bot and pin lists may still
have other preparation costs; this change removes the measured project/group
cross-products without introducing a persistent sidebar cache.
