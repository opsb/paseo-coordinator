# paseo-coordinator

A Claude Code skill that turns one Paseo session into the coordinator for all your other agent
sessions. Agents work in parallel; you are serial. The coordinator spends your attention well: it
finds the sessions that need you, orders them to cut context switching, and brings them to you one
card at a time with just enough refresher to act.

## What it does

- **Sweeps** every Paseo session in the project (or every project with `all`) and classifies each:
  Blocked, Ready, Stuck, Working, Relay or Parked. It nudges stuck sessions and re-checks old blockers
  itself, so neither reaches you.
- **Orders the queue** by stream, then area, then project, never breaking a run of related items.
  Within that, quick decisions that free the most agent work go first.
- **Shows one card at a time**: Decide, Do or Accept. The refresher grows with the time since you last
  touched the stream.
- **Keeps an inbox between sittings**: a background worker adds cards as sessions stop, and wakes the
  coordinator only when something new needs you and you are not already mid-card.
- **Marks each stream with a motif**, one emoji used on the board, every card and the start of its
  Paseo workspace title, so you know which stream you are in before reading.
- **Holds interruptions** until the current card closes, and warns when work arrives faster than you
  clear it.
- **Keeps state** in Paseo labels on each session, so it survives compaction.

Every rule is tied to a published finding in [`research.md`](skills/coordinator/research.md).

## Requirements

- Claude Code, and Paseo with its CLI and MCP server.
- macOS for the inbox worker, which runs from launchd.
- `jq`, and `gh` for PR and CI checks.
- Optional: an account wrapper at `~/Projects/paseo-claude-accounts/scripts/claude-accounts.zsh`.
  `sweep.sh` uses it to run each sweep worker under the right Claude account, and falls back to the
  default account without it.

## Install

```bash
git clone https://github.com/opsb/paseo-coordinator ~/Projects/paseo-coordinator
ln -s ~/Projects/paseo-coordinator/skills/coordinator ~/.claude/skills/coordinator
~/.claude/skills/coordinator/tick-install.sh      # starts the inbox worker and prints its status
```

The coordinator also installs the worker itself the first time it finds it missing.

## Talking to the coordinator

### Starting a sitting

| You say | What happens |
|---|---|
| `/coordinator` | This session becomes the coordinator for every session in its Paseo project. |
| `/coordinator all` | The same, for every project on this machine's Paseo daemon. |
| "board", "show the board" | It shows the board again: how many need you, what is next, what is working. |

### Answering a card

Every card ends with the replies it accepts. A Decide card asks for one word, a Do card for an action
only you can take, and an Accept card for finished work.

| Reply | Effect |
|---|---|
| `y` / `n` | Answers a Decide card. On an Accept card, `y` accepts the work and closes the session; `n` asks what next. |
| `done` | You did what a Do card asked; the coordinator tells the session. |
| `park` (or "later", "not now") | Sets a reminder for 09:00 on the next working day; the card leaves the queue. |
| `remind <when>` | Sets a reminder for that time, e.g. `remind tomorrow`, `remind me at 3`, `remind Monday`. A day without a time means 09:00. The inbox worker brings the stream back as a card when the time passes. |
| `skip` | Moves the card to the end of this sitting's queue, once. |
| `refresher` | Up to ten lines on what the stream is about, the decisions so far and what is left. Later cards for that stream get a fuller refresher. |
| `more` | The session's last message in full. |
| anything else | Passed to the session as your answer, with your reason and any constraint you add. |

### Working hours and the clock

| You say | What happens |
|---|---|
| "clock on" (also "clocking on", "clock in") | The inbox worker runs from now, whatever the working hours, until you clock off. The coordinator catches up and shows the board. |
| "clock off" (also "clocking off", "clock out", "done for the day") | The worker pauses until the working hours next begin. The coordinator gives its closing recap and says when the worker runs again. |
| "clock off until I clock on", "clock off for the weekend" | The worker stays paused until your next clock on. |
| "work 7 till 11", "change the hours to 07:30–23:00" | New working hours, read back to you in 24-hour times. Name a time zone if it isn't London. |

Whenever the worker is off, the coordinator says so: at the top of the board, before it goes quiet
after the last card, and in its closing recap, with the time it next runs.

## The schedule

launchd runs `tick.sh` every 60 seconds, all day, as the job `com.<user>.coordinator-tick`. Each tick
first decides whether the worker is on:

1. **Clocked on**: on, whatever the hours.
2. **Clocked off**: off, until the pause ends (the next start of the working hours, or your next clock
   on).
3. **Otherwise**: on within the working hours, off outside them. The default is 08:00–22:00
   London time.

When it is off, the tick stops there and costs nothing. When it is on, it:

- brings back any stream whose reminder has passed, as a card;
- finds sessions that have stopped since the last tick and whose conversation has changed, and has
  one read-only sweep worker per project read them;
- adds a card to the inbox for each session that needs you, and a nudge for each stuck one, which the
  coordinator handles without you;
- wakes the coordinator only if new cards arrived, you are not mid-card, and it is idle. Otherwise the
  cards wait in the inbox until the current card closes.

When the working hours turn the worker on or off by themselves, the next tick sends the coordinator a
one-line notice, which it passes on after the current card. Clocking on or off, or changing the
hours, is never announced; the coordinator tells you itself.

A tick that reads nothing starts no model. A tick that reads changed sessions runs one sweep worker
per project, about 10 to 20 cents each at API rates. Signed in with a Claude subscription, that comes
out of the plan's usage limits; nothing is billed. `tick.log` records it as `usage=`, and has a line
only for ticks that read, added or woke something.

### Changing the schedule

| To change | Do this |
|---|---|
| The working hours | Tell the coordinator, or run `clock.sh hours 07:30-23:00`. Add a zone for another time zone: `clock.sh hours 09:00-17:30 America/New_York`. A start after the end spans midnight (`20:00-02:00`); equal start and end mean always on (`00:00-00:00`). |
| Today only | "clock on" or "clock off", or `clock.sh on` / `clock.sh off`. |
| A long pause | `clock.sh off --until-clock-on`, then `clock.sh on` when you are back. |
| How often it ticks | Edit `StartInterval` (seconds) in `tick-install.sh`, then run `tick-install.sh` again. |
| Whether it runs at all | `tick-install.sh --uninstall` removes the job; `tick-install.sh` puts it back. |

The hours and clock live in `~/.local/state/coordinator/config.json`. Change them with `clock.sh`,
which checks the times and the zone; the file's shape, for reference:

```json
{"hours": {"start": "08:00", "end": "22:00", "timezone": "Europe/London"},
 "clock": {"mode": "auto", "since": null, "until": null}}
```

`mode` is `auto` (follow the hours), `on` or `off`. `until` is when an `off` ends, in epoch seconds,
or `null` for "until the next clock on". Without the file, the defaults above apply.

## Scripts

All live in `~/.claude/skills/coordinator/`. The coordinator runs them for you; you can also run them
yourself.

### `clock.sh`

```bash
clock.sh status                        # one line: on or off, why, and until when
clock.sh on                            # clock on: run now, whatever the hours, until clock off
clock.sh off                           # clock off: pause until the working hours next begin
clock.sh off --until-clock-on          # clock off until the next clock on
clock.sh hours 07:30-23:00 [<zone>]    # new working hours; zone is an IANA name, default unchanged
```

Each prints the new status, e.g. `Inbox worker: off, outside working hours 08:00–22:00 London time;
it starts again at 08:00 tomorrow.` It is the only writer of `config.json`.

### `tick-install.sh`

```bash
tick-install.sh                        # install or reinstall the launchd job, then print the status
tick-install.sh --uninstall            # remove it
```

Any `COORD_*` variables set when installing are passed to every tick; see Testing.

### `tick.sh`

One tick, as launchd runs it. Run it by hand to catch up straight away; it takes a lock, so it never
overlaps the scheduled tick. `COORD_ANYTIME=1 tick.sh` reads once even while the worker is off,
without clocking on.

### `inbox.sh`

```bash
inbox.sh open <scope>                  # list open cards
inbox.sh done <scope> <session-id>     # tick off that session's card
inbox.sh path <scope>                  # where the inbox file is
inbox.sh add <scope> <key> <session-id> <motif> <stream> <kind> <ask>   # used by tick.sh
```

`<scope>` is `all` or a Paseo projectId. The worker only adds cards and the coordinator only ticks
them off, both through this script and its lock, never with an editor. A card line reads:

```
- [ ] 🔑 Google sign-in · do · Run the gate sync · <session-id> · 2026-10-25 18:52 <!-- <key> -->
```

### `sweep.sh`

```bash
sweep.sh <project-dir> <sessions-json-file>
```

Starts one read-only sweep worker (a headless Claude) in the project's directory, so it loads that
project's rules and memory, and prints its JSON report. It skips your user-level hooks and settings,
and reports its usage on stderr. The brief and report format are in `sweep-worker.md`.

### `hooks/paseo-phase.sh` (optional)

Prefixes each workspace title with the agent's phase (`[Planning]`, `[Implementing]`, `[Verifying]`,
`[In review]`) and keeps a leading motif first. Link it and register it on `UserPromptSubmit` and on
`PreToolUse` with matcher `Edit|Write|MultiEdit|NotebookEdit|Bash|EnterPlanMode`:

```bash
ln -s ~/Projects/paseo-coordinator/hooks/paseo-phase.sh ~/.claude/hooks/paseo-phase.sh
bash hooks/paseo-phase.test.sh         # title cases, motif included
```

`PASEO_PHASE_DRY_RUN=1` prints the phase and title instead of renaming.

## Testing without side effects

Every script reads these variables, so a dry run touches no real state, sends nothing and starts no
model:

| Variable | Effect |
|---|---|
| `COORD_STATE_ROOT` | Use this directory instead of `~/.local/state/coordinator`. |
| `COORD_NOW` | Pretend it is this time (epoch seconds), to test the hours and the clock. |
| `COORD_ANYTIME=1` | Treat the worker as on at all hours. |
| `COORD_DRY_SEND=1` | Write wakes and notices to `<scope>/wakes.log` instead of sending them. |
| `COORD_ID` | Serve this live session as the coordinator, whatever its labels. Without it, the tick serves every session labelled `coord-role=coordinator`. |
| `COORD_SCOPE` | Use this scope instead of the coordinator's `coord-scope` label. |
| `COORD_ASSUME_IDLE=1` | Treat the coordinator as idle. |
| `COORD_ONLY_IDS` | Only these sessions, space-separated; `none` reads none, so no model starts. |
| `COORD_RECORDS_DIR` | Read Paseo agent records from here instead of `~/.paseo/agents`. |
| `COORD_KEEP_WORK=1` | Keep each tick's working files and log where they are. |
| `COORD_SKIP_JOB_CHECK=1` | `clock.sh status` skips checking that the launchd job is loaded. |

For example, the off-notice at the end of the working hours, sent (dry) to any live Paseo session:

```bash
export COORD_STATE_ROOT=/tmp/coord-test COORD_DRY_SEND=1 COORD_ASSUME_IDLE=1 COORD_ONLY_IDS=none
export COORD_ID=<a live Paseo session id> COORD_SCOPE=all
at() { TZ=Europe/London date -j -f '%Y-%m-%d %H:%M' "$1" +%s; }
COORD_NOW=$(at "2026-10-25 21:59") ~/.claude/skills/coordinator/tick.sh
COORD_NOW=$(at "2026-10-25 22:01") ~/.claude/skills/coordinator/tick.sh
cat /tmp/coord-test/all/wakes.log       # one notice: the worker is now off until 08:00 tomorrow
```

## Files

State, in `~/.local/state/coordinator/`:

| File | Holds |
|---|---|
| `config.json` | working hours and clock, written by `clock.sh` |
| `worker-state` | whether the last tick found the worker on or off, so it announces each change once |
| `tick.log` | one line per tick that read, added or woke something, and any error |
| `launchd.log` | anything the job printed outside the log; empty when all is well |
| `<scope>/inbox.md` | the cards |
| `<scope>/seen.json` | each session's last-read state, so it is read again only when its conversation changes |
| `<scope>/wake-pending` | new cards the coordinator has not been woken for yet |

The worker relies on Paseo's on-disk agent records in `~/.paseo/agents`, which are undocumented; if
Paseo changes their shape, the tick logs an error and stops rather than guessing.

Repository:

| File | Purpose |
|---|---|
| `skills/coordinator/SKILL.md` | the coordinator's instructions |
| `skills/coordinator/research.md` | the evidence behind each rule |
| `skills/coordinator/clock.sh` | clock on, clock off, working hours and status |
| `skills/coordinator/schedule.sh` | the hours and clock logic shared by `tick.sh` and `clock.sh` |
| `skills/coordinator/tick.sh` | one tick of the inbox worker |
| `skills/coordinator/tick-install.sh` | installs or removes the launchd job that runs it |
| `skills/coordinator/inbox.sh` | adds, lists and ticks off cards in the inbox, under one lock |
| `skills/coordinator/sweep.sh` | starts a read-only sweep worker in a project's directory |
| `skills/coordinator/sweep-worker.md` | the sweep worker's brief and report format |
| `hooks/paseo-phase.sh` | the optional phase hook |
| `hooks/paseo-phase.test.sh` | its title test |

## Limits

It works only with Paseo, and only with the daemon on the machine it runs on. It relies on Paseo for
session status, the time of your last message, sending prompts to sessions, and labels. The inbox
worker needs macOS and launchd.
