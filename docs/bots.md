# Bots

A Bot is a standing role you message from any project: one job, its own
memory, routines it starts by itself, and one standing chat. Bots are graff's
(codegraff ADR 0333 and 0334). graff keeps them in its home
(`~/.graff/bots`) and owns the wording of every prompt; Harness runs
`graff bot --user …` and keeps nothing itself.

## Experimental, and off until you turn them on

Settings › Agents has an **Experimental: Bots** card with one switch. It is
graff's switch (`graff bot enable`, the file `~/.graff/bots/enabled`), so
turning bots on in a terminal turns them on here and the other way round.
`GRAFF_BOTS=1` or `=0` in the engine's environment decides instead of the
file.

While bots are off:

- the engine starts no graff for them, checks no routine, and answers
  `BotsState` with `enabled: false` and an empty list;
- `BotDetail`, `RunBot` and every `BotAction` but `enable` and `disable`
  refuse with "Bots are off. Turn them on in Settings › Agents.";
- the window draws no Bots group, no catch-up and no bot strip. A bot's
  standing chat, if it has one from before, is an ordinary chat in the list.

Turning them off keeps every bot, its memory and its routines. The card is
shown for this device only: another device's switch is flipped there.

## Where they are

- **The Bots group**, in the sidebar under the chats, on every project
  filter. A row shows the bot's name, the project it works in, and what it
  needs: a question waiting, a failure, a finished run not yet read, a routine
  that did not run. A bot's standing chat is listed there and not among the
  sessions.
- **A bot's chat** is an ordinary graff chat with a strip naming the bot.
  Details opens its page: its job, routines, memory and recent log.
- **The catch-up** lists what needs looking at, most pressing first. The
  pill on the Bots header opens it. After a launch that follows a stretch in
  which nothing checked routines, the window opens on it.

## What the engine does

| RPC | |
|---|---|
| `BotsState` | Whether bots are on, every bot, its routines, the last check and the last gap. Off: `enabled: false` and nothing else, without starting graff. |
| `BotDetail {bot}` | Its memory and recent log. |
| `BotAction {action, …}` | Turn bots on or off (`enable`, `disable`), create, remove, set a field, add or pause a routine, forget a memory entry, clear a missed routine. Returns the state after. |
| `RunBot {bot, message \| routine}` | Puts a turn into the bot's standing chat, creating it on the first run. |

A run is a turn in the bot's chat. The chat is made in the bot's project on
the first run and remembered on the bot (`graff bot set NAME chat ID`) before
the turn is queued. While a turn is running or a question is open, the next
one waits behind it. A routine's turn carries the bot's current standing text,
since its memory may have changed since the chat began.

Approvals follow the chat. A bot created with `graff bot create --yolo` skips
approvals in headless `graff bot` runs only; the engine never passes that to
a chat.

## Routines run only while Harness is open

The engine checks routines once a minute for as long as it runs. Nothing
checks them when it is not running or the machine is asleep.

A slot that came due more than five minutes before a check is not run late.
graff records it on the routine, and the catch-up shows it as "Did not run"
with the time it was due. Run now starts a new turn at the present time;
Dismiss clears it. The banner says between which times nothing was checking.
It does not say why: the engine cannot tell a closed lid from a quit.

Schedules are graff's: a delay (`30m`, once) or `@every` and a period. There
are no weekday or clock times.

## The primary bot

One bot can be primary. Its standing text lists your other bots and tells it
to say whose job a request is and wait for your yes. The `run_bot` MCP tool,
called with no project, puts the turn into the named bot's standing chat, so
a handoff lands where that bot's other work is.

The wait for a yes is an instruction to a model, not something the engine
enforces. A chat that asks before running tools asks before `run_bot` too.

## Limits

- Bots are on the device whose graff home holds them. A project on another
  device is not offered to a new bot, and there is no queue for a device that
  is offline.
- Bots kept in one project's `.graff/bots` are not in the Bots group. The
  `list_bots` and `run_bot` MCP tools still reach them by project.
- A graff from before per-user bots answers "update graff", under the switch
  in Settings when that is where it was asked. An engine from before bots has
  no Bots group and no card.
- The phone apps do not show bots yet.
