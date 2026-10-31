Native GPUI screenshots of the Run settings card from the isolated fixture
with made-up values, at 2x.

```sh
HARNESS_DIAL_SCENE=run cargo run -p harness-ui --example dial-panel-fixture
HARNESS_DIAL_SCENE=run HARNESS_FIXTURE_APPEARANCE=light cargo run -p harness-ui --example dial-panel-fixture
```

`run-*-before.png` is the first cut of the card; `run-*-after.png` is this
branch. The card is a solid popover surface, not glass.
