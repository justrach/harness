# Harness interface design

This document records the interface that Harness currently ships. It is a reference for extending the desktop app without changing its visual language. The implementation remains the source of truth: [`crates/ui/src/theme.rs`](crates/ui/src/theme.rs), [`crates/ui/src/settings/widgets.rs`](crates/ui/src/settings/widgets.rs), and [`docs/theme-system.md`](docs/theme-system.md).

## Product shape

Harness is a native workspace for coding agents. Its persistent sidebar holds spaces, sessions, navigation, and account status; the main panel holds a conversation, files, terminal, or settings. A compact composer stays close to the transcript. Settings use a quiet left navigation and a centered content column. The interface favors readable work over decorative chrome.

New installs select **Codegraff Light** and **Codegraff Dark**. These are two authored palettes, not color inversions. Users can choose other bundled or imported themes, an independent accent, and a frosted or opaque surface preference. UI components consume semantic theme roles instead of hard-coded theme colors.

## Color and surfaces

| Role | Codegraff Light | Codegraff Dark |
| --- | --- | --- |
| Main background | `#faf8f3` | `#16140f` |
| Sidebar and cards | `#f0ece3` | `#1f1c16` |
| Raised control | `#e7e1d5` | `#2a261e` |
| Primary text | `#1a1813` | `#edeae2` |
| Muted text | `#6b6557` | `#9a9384` |
| Accent | `#c77d20` | `#e8a33d` |

The Codegraff palettes recommend frosted surfaces, like the Harness palettes before them: the window blurs what sits behind it, tinted from the mapped shell roles. The **Frosted glass** switch in Settings → Appearance turns that off. In light mode the white content plane advances and the warmer sidebar recedes; in dark mode the content plane is darkest and raised controls get lighter. Borders and restrained shadows separate light cards. Accent marks actions, focus, selection, activity, and usage below warning thresholds. Warning, danger, success, diff, syntax, and terminal colors keep their own meanings. Palette definitions live in [`crates/theme/src/builtins.rs`](crates/theme/src/builtins.rs).

## Type, rhythm, and shape

- Geist is the default interface face; Geist Mono is available for fixed-width UI, code, and terminal surfaces. The user can change interface, code, and terminal typography independently.
- Settings pages use a centered column no wider than **768 px**, with **24 px** side padding, **32 px** top padding, and **64 px** bottom padding. Titles are **16 px semibold**, subtitles **13 px muted**, and compact row titles/descriptions **13/12 px**.
- The base spacing steps are **4, 8, 12, and 16 px**. Closely paired labels and descriptions can use a 1 px optical gap.
- Message bubbles use a **16 px** radius, panels and cards **10 px**, and small controls **6 px**. Borders are hairlines; they organize the page without turning every item into a box.
- Hover, active, focused, disabled, loading, warning, and error states have distinct treatments. Motion should explain a state change and leave content legible.

## Settings and account cards

Settings pages share `PageScroll`, `page_column`, `page_header`, `page_subtitle`, and `section_card` from [`crates/ui/src/settings/widgets.rs`](crates/ui/src/settings/widgets.rs). The Accounts page in [`crates/ui/src/settings/accounts.rs`](crates/ui/src/settings/accounts.rs) groups logins by provider. Each group has a brand glyph and an Add account action; its rows show identity, active state, plan, usage windows, and account actions. A quiet device switcher in the header changes which host's local agent logins are shown.

Usage belongs **inside the existing account row**. Each window uses a short label, a 5 px rounded meter, a percentage, and a subdued reset time. It uses the theme accent below 80% used, warning at 80%, and danger at 95%. Keep the provider ordering and card geometry stable as live values refresh; loading or unavailable data should not rearrange the page. The CodeGraff account section uses the same card geometry for credit balance, recent spending, and an optional monthly key-budget meter. It reads the selected device's Graff CLI account; Harness sync sign-in is a separate account state.

## Conversation and interaction

The conversation is the primary work surface. User messages and agent output have distinct alignment and hierarchy; tool calls, code, files, errors, and timestamps remain readable within the same transcript. The composer shows the selected agent, model, and reasoning level without hiding the prompt. Once a chat exists, its agent is fixed; model and reasoning changes stay within that agent. Popovers and dialogs use the same theme roles and compact controls as the rest of the shell.

Use plain, specific copy for actions with data consequences. Local versus synced workspace state belongs in the account area. Importing existing chats into sync requires an explicit choice, and the interface should state when another signed-in device can request access to the host's workspace.

## Model picker

One composer chip opens one card: a favorites star and one brand icon per offered agent across the top, a search row, the model list, and a pinned tray for reasoning and model options. An existing chat shows only its own agent. A search filters the viewed tab only; switching tabs re-scopes the same query. Rows on an agent tab are compact single lines: model name, muted attribution, a ⌘1–⌘9 chip, and a star. The favorites tab mixes agents, so its rows add a brand subline. Hover moves the one keyboard highlight; the selected model gets the stronger wash and ring.

Some agents serve models from several providers at once. Graff lists every provider the account is signed in to, and opencode lists its connected providers, both as `provider/model` ids. When an agent tab spans two or more providers, its rows sit under provider headers in first-appearance order, so the current model's provider leads. Starred models get a **Starred** section on top. Headers are **11 px semibold** muted text at exactly the height of a row, because the list is virtualized and sizes every item from the first. They are never highlighted or picked, and arrows and ⌘N skip them. A row under a header drops the provider prefix from its attribution ("kimi · 262k context" reads "262k context"). Single-provider tabs and search results stay flat. See `scoped_model_rows` and `render_model_header` in [`crates/ui/src/pickers.rs`](crates/ui/src/pickers.rs).

## Tabs, split panes, and composer picks

⌘D and ⌘⇧D split the conversation column like Ghostty; ⌘T opens a tab. When another side-by-side pane would fall below **380 px**, ⌘D opens a tab instead. The focused pane is the selected chat with the composer; other panes are dimmed, read-only transcripts, and clicking one moves focus there.

Each tab and pane owns its selection, project filter, and composer picks (agent, model, reasoning). A new pane or tab starts from the picks of the pane it was opened from. Leaving a pane or tab parks its picks, and coming back restores them. The sticky last-used defaults only seed a new-session canvas with nothing parked, such as after a restart. An existing chat's picks live on the chat itself. See [`crates/ui/src/shell/chat_split.rs`](crates/ui/src/shell/chat_split.rs) and [`crates/ui/src/shell/chat_tabs.rs`](crates/ui/src/shell/chat_tabs.rs).

## Extending the design

Reuse semantic `Theme` colors, typography helpers, shared settings widgets, existing icons, and the current account-row layout. Check both Codegraff appearances and a contrasting third-party theme. Review ordinary, hover, focus, loading, offline, error, and high-usage states. [`docs/theme-system.md`](docs/theme-system.md) lists the theme validation and visual review surfaces.
