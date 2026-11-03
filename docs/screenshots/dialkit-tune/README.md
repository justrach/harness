Native GPUI screenshots of the dev Tune panel from the isolated fixture with
made-up values, at 2x.

```sh
HARNESS_DIAL_SCENE=motion cargo run -p harness-ui --example dial-panel-fixture
HARNESS_DIAL_SCENE=shape HARNESS_FIXTURE_APPEARANCE=light cargo run -p harness-ui --example dial-panel-fixture
```

`*-before.png` is the first cut of the panel; `*-after.png` is this branch.
The panel is glass; on Linux (Xvfb) glass renders without blur, so it reads
nearly solid here.
