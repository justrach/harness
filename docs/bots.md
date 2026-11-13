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

## The main bot

One bot is the main bot (graff's `primary`; codegraff ADR 0335): the one
thread you keep for every project. Turning Bots on makes one, named `main`,
when the device has none. You can change its job, or make another bot the
main one on that bot's page.

You ask it for something in any project. It starts that piece of work as an
ordinary chat in the project it belongs to, tells you in one line what it
started, and ends its turn. It asks you only when it cannot tell which
project you mean. It starts work with the Harness tools every graff chat
has (`list_projects`, `create_chat`, `read_chat`, `send_message`).

**It hears back.** When a chat the main bot's thread started finishes a
turn, stops on a question, or fails, the engine puts one message into the
main bot's thread: which chat, in which project, and its last words. The
main bot then tells you what came back. (`crates/engine/src/bots_reports.rs`)

- Only a turn nobody typed is reported. If you open that chat and work in it
  yourself, those turns are yours.
- A report starts a turn of the main bot, and that turn can start more
  work. So that this cannot run on by itself: work you asked for is step 1,
  work started while the main bot was answering a report is a step further,
  and nothing past step 3 is reported (the third report says it is the
  last). One chat is reported at most four times an hour, and at most
  twenty reports go out in ten minutes. What is not reported still shows in
  the catch-up.
- Nothing is kept on disk for this. An engine that restarts does not report
  what ended before it started; the catch-up still shows it.

A chat it starts records the main bot's chat as its parent, and that is the
whole record of its work:

- **Under its row** in the Bots group: the chats it started that are still
  going or have something to read, with the project each is in.
- **On its page**: In progress, Scheduled (every bot's routines, soonest
  first) and Completed.
- **In the catch-up**: a chat it started that stopped on a question, failed,
  or finished unread, named by what it is and where.

A chat the main bot started is not listed among a project's sessions.

Your other bots are helpers: each keeps one job, and the main bot hands a
request to the one whose job it is with the `run_bot` MCP tool, which puts
the turn into that bot's standing chat.

What the main bot is told is text given to a model. The engine does not
stop it from working in its own thread, and does not make it ask before a
step that cannot be undone. A started chat's approvals are its own: one that
asks before running tools asks there, and the catch-up shows it.

## Limits

- Bots are on the device whose graff home holds them. A project on another
  device is not offered to a new bot, and there is no queue for a device that
  is offline.
- The main bot starts work in projects Harness already knows. For a folder
  that is not a project it has to be told the path.
- Work the main bot started is found under the main bot, not in the
  project's session list.
- Bots kept in one project's `.graff/bots` are not in the Bots group. The
  `list_bots` and `run_bot` MCP tools still reach them by project.
- The main bot needs graff 0.302.74.62 or later. With an older graff the
  primary bot is told only to say which bot a request is for and wait for a
  yes: it starts no chats in projects, and the engine has nothing to report.
- A graff from before per-user bots answers "update graff", under the switch
  in Settings when that is where it was asked. An engine from before bots has
  no Bots group and no card.
- The phone apps do not show bots yet.
