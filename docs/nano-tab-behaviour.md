# Tab and panel behaviour: adopting it in harness-nano

v0.2.173 put the desktop's tabs back to how they behaved before the panel
system landed, while keeping the panel layout. harness-nano has the same bugs,
so it should follow. This page says what to change and where. File names are
from `apps/nano/src` on `feat/nano-parity-gaps` at `58aecf9ba`; check them
against your checkout first.

## The rules

1. **A link, file or diff opens in a side panel beside the chat, at a set
   width.** It isn't squeezed to an equal share of a split. The other panels
   give up room in proportion and each keeps its minimum. If they can't spare
   the set width, the side panel takes what they can give, and never less than
   an equal share.
2. **Later ones join the same side panel.** They don't open another.
3. **The chat stays on screen.** Opening a link keeps the chat selected and
   showing in its own panel. The new tab has focus, so one ⌘W closes it.
4. **One close is enough.** Closing a side panel's last tab removes the panel
   and gives its room back. No empty panel or choices page is left behind.
5. **⌘W closes what's beside the chat first.** With a chat focused and a page,
   file or diff showing in another visible panel, ⌘W closes that, and the chat
   stays on screen. The next ⌘W closes the chat.
6. **Closing a tab goes back to the one you were on before.** It doesn't go to
   the neighbour that slid into its place. After a restart, with no history
   yet, the neighbour is fine.
7. **The window's only tab becomes a new chat.** A panel never sits empty with
   nothing to close. ⌘W on a window whose only tab is already a new chat does
   nothing, and keeps what's been typed.
8. **A strip slot closes with its own ✕.** It shows under the pointer when the
   slot is at least 136pt wide. Narrower slots close from their menu. Pressing
   ✕ closes the panel's selected tab; if that was its last tab, the panel goes
   too (rule 4). A slot with no tab closes its panel.

## Where each one goes in nano

| Rule | File | What to change |
| --- | --- | --- |
| 1 | `panel_chrome.zig`, `frame` | `host_width` and `files_width` use `each`, the equal share. Add a pure `sidePanelShare(width, others, preferred)` and size the host panel from it. Port the desktop's arithmetic below. Keep the content-top test as it is. |
| 2 | `app_browser.zig`, `settleFrame` | Already true: the host panel is a single tab group. Check the other openers still land there. |
| 3 | `app_browser.zig`, `settleFrame` | Set `a.view.strip.focused = .host` when the tab lands, and leave `a.selected` alone. Add a test. |
| 4 | `app_panels.zig`, `closeTab` | When `p.tabs.items.len` reaches 0, set `p.host_open = false`. Today it stays true, so `view_host.zig`'s `picker` appears and takes a second close. Also do it through `close_host_tab` in `view_tab_strip.zig`. |
| 5 | `app.zig`, `closeByShortcut` | In the `.chat` arm, before the archive question: if `hasHost(a)` and the host is visible (not hidden by `strip.expanded`) with a tab open, call `closeTab(a, a.panels.active)` and return. Files stay as they are: the desktop rule doesn't cover the explorer. |
| 6 | `tabs.zig`, `closePaneTab`, `Tabs.close` and `app_panels.zig`, `closeTab` | All three pick by position. Keep a list of what each group has shown, latest first, and pick the first survivor. The desktop's is `shown` plus `active_after_close`, and it isn't saved. |
| 7 | `tabs.zig`, `Tabs.close` and `app.zig`, `closeByShortcut` | `close` already calls `setCurrent(null)` for the last tab. Confirm that lands on a new chat. Add the no-op for ⌘W when the only tab is already a new chat. |
| 8 | `view_tab_strip_render.zig`, `slot` and `panel_chrome.zig` | Add `slot_room_for_close = 136`. Draw a hover ✕ after the menu when `width >= slot_room_for_close`, and add 24 to `controls` for its room. Queue `close_panel_tab` or `close_host_tab`, as the slot's panel needs. |

The side panel's share, from `side_panel_share` in
`crates/ui/src/shell/workspace_panels.rs`:

```text
equal     = 1 / (others + 1)
available = width - gutter * others
if available <= 0: return equal
room      = available - others * panel_min
return clamp(min(preferred, room) / available, equal, 1)
```

`preferred` is the saved side pane width: `right_pane_width` in Settings,
520 by default. `panel_min` is already 220 in `panel_chrome.zig`.

Only the row layout uses this. Stacked panels stay equal.

## Tests to port

The desktop's are in `crates/ui/src/shell/link_tests.rs` and
`crates/ui/src/shell/workspace_panels/instrument_strip_tests.rs`:

- `a_link_opens_beside_the_chat_at_the_side_panes_width`
- `a_link_in_a_split_is_not_squeezed_to_an_equal_share`
- `a_side_panel_gets_the_old_width_when_the_others_can_spare_it`
- `a_second_link_joins_the_panel_already_holding_a_page`
- `closing_a_linked_page_once_gives_the_chat_its_room_back`
- `command_w_closes_the_page_beside_the_chat_before_the_chat`
- `closing_the_only_tab_moves_on_to_a_new_chat`
- `closing_a_split_page_leaves_no_empty_panel_to_close_again`
- `closing_the_tab_you_are_on_goes_back_to_the_one_before_it`
- `a_new_tabs_slot_can_be_pressed_and_closed`

The nearest places in nano are `tests_ui_surfaces.zig`, `tests_ui_split.zig`
and `tests_ui_tab_strip.zig`. `panel_chrome.zig` already has pure geometry
tests, so `sidePanelShare` can sit with them, with the same numbers as the
desktop's test.

## What not to change

- The layout: folder tabs with one panel, one strip with a slot per panel when
  split.
- The sidebar's "Close session" dialog. That closes a whole session, not a tab.
- ⌘T and the + buttons.

Parity frames that show a host panel will move, because its width changes.
Re-record those baselines in the same change.
