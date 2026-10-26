# Model picker preview — DO NOT MERGE

This is an internal native interaction experiment, not a public release. The live agent catalog supplies selectable model IDs, available options and reasoning levels. Ratings, strengths/tradeoffs, category membership, and dollar ranges are **dummy data**, including their relationship to effort. They are not benchmarks or price quotes.

## Run and review

The experiment requires the `harness-ui/model-picker-preview` Cargo feature, a build with debug assertions, and `HARNESS_MODEL_PICKER_PREVIEW=1`. Default builds keep the existing picker. Release builds cannot enable the preview through the environment. The offline fixture explicitly enables it in debug builds and never creates an engine or reads real account data:

```sh
cargo run -p harness-ui --example model-picker-fixture \
  --features model-picker-preview,appshots-fixture
```

Fixture switches: `--legacy`, `--dark`, `--narrow` (540 × 680), `--large` (7,000 extra models), `--model=openai/gpt-5.4`, `--hover=anthropic/claude-sonnet-4.6`, and `--output=/tmp/model-picker.png`. Combine `--model` with `--record=/tmp/picker-frames` to capture native pointer-driven drag and release frames. An output run saves its rendered window and exits. The normal fixture is interactive at 860 × 680. Example model names and capabilities are synthetic fixtures, not a claim about today's availability.

For integration in a separately configured development app, build `cargo build -p harness --features harness-ui/model-picker-preview` and launch with the preview environment variable plus its own `HARNESS_DATA_DIR` and `HARNESS_IPC_PORT`. Do not reuse the production data directory or an already running development instance.

## Behavior

- Provider logos appear once per group. Mixed shortlists and search results carry maker logos per row. The model maker supplies the reasoning accent; the detail card separately names the serving route.
- All live models remain selectable, including unknown/custom providers. Icons and profile metadata are presentation only; they never whitelist model IDs. Unrated models say so and remain in All.
- Search, arrow navigation, favorites and model shortcuts share the same cached, virtualized rows. The 356px picker opens without a detail pane. A floating card appears beside a hovered row after 180ms (or on explicit keyboard navigation), with 160ms grace to enter the card. It flips sides when there is room and stays within the window on narrow screens. Context appears in that card, not model rows.
- The separate reasoning screen uses the app's shared type, surfaces, and buttons. A neutral thumb follows the pointer continuously over the provider-colored track, then eases to the nearest supported stop over 150ms. Keyboard changes use the same settling motion; reduced motion snaps immediately.
- Choosing a model stages it. The second screen offers only its advertised reasoning ladder and model options. Binary ladders say Off/On; an empty ladder has no slider.
- Back/Escape from reasoning discards the staged selection. Use model applies model, reasoning and options together. A chat's agent stays fixed. Catalog changes are revalidated before applying.
- Subscription/local routes do not display fictional API charges. Unknown estimates are not zero.

## Provider audit

The built-in registry was checked against [`src/provider.zig`](https://github.com/justrach/codegraff/blob/c9c89ada4afa4f5a4d3b6a7612626ca1a747a2af/src/provider.zig) and `spec/kernels/providers.json` on 2026-10-23. There are **25 built-in routes plus an optional custom router**. This is not the same as the set of model makers. The runtime catalog remains authoritative for availability and capabilities.

| Route | Heading mark | Accent source or fallback |
| --- | --- | --- |
| anthropic | Claude | Anthropic orange `#d97757` |
| codegraff | Codegraff | Site `--color-accent: #0285ff` |
| deepseek | DeepSeek | Site `--dsw-static-deepseek-500: #3964fe` |
| openai | OpenAI | Apps SDK UI blue-200 `#66b5ff` |
| google | Gemini | Gemini `--gem-sys-color--brand-blue: #3186ff` |
| minimax | MiniMax | Site `--col-accent00: #1887fb` |
| xiaomi | MiMo | Xiaomi `--orange-orange100: #ff6900` |
| kilo | Kilo | Site `--brand-primary: #ffdd00` |
| groq | Groq | Site `--color-orange-brand` → `#f43e01` |
| cerebras | Cerebras | Site `--color-cerebras-orange: 15 88% 55%` |
| mistral | Mistral | Site `--color-orange-strong` → `#ff5229` |
| kimi | Kimi | Brand book blue `#007cff` / `#00a1ff` |
| moonshot | Kimi | Same Kimi product palette |
| xai | Grok | Monochrome |
| zai | Z.ai | Site monochrome `--accent` |
| meta | Meta | Neutral pending a verified current product accent |
| vercel | Vercel | Monochrome |
| openrouter | OpenRouter | Site `--primary: 239 84% 67%` |
| fugu | Sakana | Site `--accent: #e10600` |
| fireworks | Fireworks | Site brand-bloom-600/100 `#7a155c` / `#ffc0e7` |
| mlx | Official MLX wordmark | Monochrome |
| lmstudio | LM Studio | Site marketing-accent / accent-border `#4338ca` / `#7b74db` |
| omlx | Official oMLX favicon | Site monochrome `--accent` |
| chatgpt-new | OpenAI | OpenAI product blue |
| codex | OpenAI | OpenAI product blue |
| Custom / unknown | Neutral globe | Neutral until metadata is supplied |

Maker metadata takes precedence over the route for the selected model's mark and accent. For example, Claude through OpenRouter keeps Anthropic's accent, with “via OpenRouter” visible. Additional makers such as Qwen keep existing bundled marks and a neutral accent until sourced. No corporate logo is recolored to match the slider.

### Color evidence

The named CSS tokens above were read from styles linked by these first-party pages on 2026-10-23: [Codegraff](https://codegraff.com/), [DeepSeek](https://www.deepseek.com/), [Gemini](https://gemini.google.com/), [MiniMax](https://www.minimax.io/), [Xiaomi](https://www.mi.com/global/), [Kilo](https://kilo.ai/), [Groq](https://groq.com/), [Cerebras](https://www.cerebras.ai/), [Mistral](https://mistral.ai/), [Z.ai](https://z.ai/), [OpenRouter](https://openrouter.ai/), [Sakana](https://sakana.ai/), [Fireworks](https://fireworks.ai/), [LM Studio](https://lmstudio.ai/), and [oMLX](https://omlx.ai/). These are observed product/website palettes, not claims that every value is an official corporate primary color.

Explicit references: [OpenAI Apps SDK primitives](https://github.com/openai/apps-sdk-ui/blob/main/src/styles/variables-primitive.css), [Anthropic brand guidelines](https://github.com/anthropics/skills/blob/main/skills/brand-guidelines/SKILL.md), [Kimi brand book](https://www.kimi.com/en/resources/kimi-brand). OpenAI's blue is a product UI choice; the Blossom stays monochrome. Meta's public page returned a client challenge, so its accent remains neutral.

Additional provider marks use LobeHub Icons 1.98.0, alongside the existing 1.95.1 maker marks. MLX and oMLX use the upstream project SVGs. See `THIRD_PARTY_NOTICES.md` and the retained asset licenses.

## Public merge blockers

1. Replace dummy ratings, shortlists and strengths/tradeoffs with reviewed, versioned metadata backed by evaluations. Do not infer recommendations from model-name substrings in public builds.
2. Replace dummy dollar ranges with an estimator using effective route prices and measured whole-task usage, including retries, tools, child agents, caching and effort. Keep unknown usage distinct from zero; avoid counting reasoning tokens twice. Subscription plan limits and API charges need separate treatment.
3. Calibrate ranges on held-out tasks across providers, model versions and reasoning levels. Track coverage/error and handle missing pricing explicitly. The current linear fixture multiplier is not an assertion about how reasoning affects real cost.
4. Finish remaining maker accent verification (including Meta and Qwen), review logo sizing and accessibility, and verify pointer/keyboard behavior in the full isolated app on supported desktop platforms.
5. Remove the experiment gate only after those requirements pass. A draft PR and this warning are review safeguards, not an automated merge prohibition.

## Validation

All 61 picker tests pass, including ten preview tests covering staged cancellation, browsing agents without changing run configuration, atomic existing-chat updates, changed catalog capabilities, binary/fixed reasoning, subscription/local cost labels, pointer drag and keyboard changes, hover-card timing and pointer transfer, intermediate slider settling frames and reduced motion, reopening All after a shortlist, and all built-in plus custom routes in a 7,000-model catalog. The default UI library also passes `cargo check` with the feature off. Native fixture captures cover light/dark at 860 × 680 and light at 540 × 680; all use synthetic data. Full-app and other-platform verification remain public merge blockers.
