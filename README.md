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
- **Shows one card at a time**: Decide, Do or Accept. The refresher grows with time since you last
  touched the stream. Reply `y`, `n`, `park`, `skip`, `refresher` or `more`, or in your own words.
- **Marks each stream with a motif**, one emoji used on the board, every card and the start of its
  Paseo workspace title, so you know which stream you are in before reading.
- **Holds interruptions** until the current card closes, and warns when work arrives faster than you
  clear it.
- **Keeps state** in Paseo labels on each session, so it survives compaction.

Every rule is tied to a published finding in [`research.md`](skills/coordinator/research.md).

## Requirements

- Claude Code, and Paseo with its CLI and MCP server.
- `jq`, and `gh` for PR and CI checks.
- Optional: an account wrapper at `~/Projects/paseo-claude-accounts/scripts/claude-accounts.zsh`.
  `sweep.sh` uses it to run each sweep worker under the right Claude account, and falls back to the
  default account without it.

## Install

```bash
git clone https://github.com/opsb/paseo-coordinator ~/Projects/paseo-coordinator
ln -s ~/Projects/paseo-coordinator/skills/coordinator ~/.claude/skills/coordinator
```

Then, in a Paseo session: `/coordinator` for the current project, `/coordinator all` for every project
on this machine's daemon.

## Phase hook (optional)

`hooks/paseo-phase.sh` prefixes each workspace title with the agent's phase (`[Planning]`,
`[Implementing]`, `[Verifying]`, `[In review]`) and keeps a leading motif first. Link it and register
it on `UserPromptSubmit` and on `PreToolUse` with matcher `Edit|Write|MultiEdit|NotebookEdit|Bash|EnterPlanMode`:

```bash
ln -s ~/Projects/paseo-coordinator/hooks/paseo-phase.sh ~/.claude/hooks/paseo-phase.sh
bash hooks/paseo-phase.test.sh   # title cases, motif included
```

## Files

| File | Purpose |
|---|---|
| `skills/coordinator/SKILL.md` | the coordinator's instructions |
| `skills/coordinator/research.md` | the evidence behind each rule |
| `skills/coordinator/sweep.sh` | starts a read-only sweep worker in a project's directory |
| `skills/coordinator/sweep-worker.md` | the sweep worker's brief and report format |
| `hooks/paseo-phase.sh` | the optional phase hook |
| `hooks/paseo-phase.test.sh` | its title test |

## Limits

It works only with Paseo, and only with the daemon on the machine it runs on. It relies on Paseo for
session status, the time of your last message, sending prompts to sessions, and labels.
