Native GPUI screenshots of the hold-H walkthrough on the Run settings card,
from the isolated fixture with made-up values, at 2x.

```sh
HARNESS_DIAL_SCENE=run cargo run -p harness-ui --example dial-panel-fixture
HARNESS_DIAL_SCENE=walkthrough cargo run -p harness-ui --example dial-panel-fixture
```

`run-*-before.png` is the card without the walkthrough. `run-*-after.png`
shows the H Explain key at the card's foot, and `walkthrough-*-after.png`
shows H held over Sandbox: that row gets a wash and a one-line hint.
