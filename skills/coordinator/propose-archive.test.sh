#!/usr/bin/env bash
# Checks propose-archive.sh against a throwaway origin, a worktree, session records and a real inbox.
# GitHub and Paseo are stubbed, so it touches no real workspace. Run: bash propose-archive.test.sh
set -uo pipefail

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export COORD_STATE_ROOT=$T/state COORD_RECORDS_DIR=$T/agents
export COORD_NOW=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' 2026-10-26T16:00:00Z +%s)
mkdir -p "$COORD_STATE_ROOT" "$COORD_RECORDS_DIR/proj"
source "$(dirname "$0")/propose-archive.sh"

pass=0
fail=0

expect() {
  local name=$1 expected=$2 actual=$3
  if [[ $actual == "$expected"* ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual"
  fi
}

# --- Fixtures ------------------------------------------------------------------------------------

# Fixture git ignores the user's own config (signing, hooks) and needs no identity of theirs.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

quiet() { "$@" > /dev/null 2>&1; }

make_repos() {
  quiet git init --bare -b main "$T/origin.git"
  quiet git clone "$T/origin.git" "$T/main"
  quiet git -C "$T/main" checkout -b main
  quiet git -C "$T/main" commit --allow-empty -m base
  quiet git -C "$T/main" push -u origin main
  quiet git -C "$T/main" remote set-head origin main
  quiet git -C "$T/main" worktree add -b feature "$T/worktrees/proj/feature"
  quiet git -C "$T/worktrees/proj/feature" commit --allow-empty -m work
  quiet git -C "$T/worktrees/proj/feature" push -u origin feature
}

WT=$T/worktrees/proj/feature
SESSION_ID=11111111-2222-3333-4444-555555555555
WORKSPACE='{"id":"wks_test","cwd":"'$WT'","title":"🔑 Test stream"}'
NO_CARDS='[]'

# A finished session, last active 30 hours before COORD_NOW; each case changes one field.
session() {
  jq -n -c --arg extra "${1:-{\}}" '{id: "'$SESSION_ID'", workspaceId: "wks_test",
    archivedAt: null, lastStatus: "idle", requiresAttention: false,
    lastActivityAt: "2026-10-25T10:00:00.000Z", lastUserMessageAt: null, labels: {}} * ($extra | fromjson)'
}
sessions() { jq -s -c . <<< "$(session "${1:-{\}}")"; }

PR_HEAD=""
merged_pr() {
  [[ -n $PR_HEAD ]] && echo '{"url":"https://github.com/o/r/pull/1","number":1,"headRefOid":"'$PR_HEAD'"}'
}

paseo() {
  case "$1 $2" in
    "workspace archive") echo "$3" >> "$T/archived" ;;
    "workspace ls") echo '[{"workspaceId":"wks_test","cwd":"'$WT'","name":"🔑 Test stream","project":"proj"}]' ;;
    "project ls") echo '[{"name":"proj","projectId":"prj_1","path":"'$T/main'"}]' ;;
    "daemon config") echo "{\"value\": ${AUTO_ARCHIVE_SETTING:-false}}" ;;
  esac
}

make_repos
PR_HEAD=$(git -C "$WT" rev-parse HEAD)

# --- What keeps a session off the list ----------------------------------------------------------

expect "finished, quiet, clean and merged" "propose {" \
  "$(verdict "$WORKSPACE" "$(sessions)" "$NO_CARDS")"
expect "a running session" "keep: a session is running" \
  "$(verdict "$WORKSPACE" "$(sessions '{"lastStatus":"running"}')" "$NO_CARDS")"
expect "a session waiting for attention" "keep: a session is waiting for attention" \
  "$(verdict "$WORKSPACE" "$(sessions '{"requiresAttention":true}')" "$NO_CARDS")"
expect "the coordinator's own workspace" "keep: the coordinator works here" \
  "$(verdict "$WORKSPACE" "$(sessions '{"labels":{"coord-role":"coordinator"}}')" "$NO_CARDS")"
expect "no live sessions" "keep: no live sessions" \
  "$(verdict "$WORKSPACE" '[]' "$NO_CARDS")"
expect "an open inbox card" "keep: a session has an open inbox card" \
  "$(verdict "$WORKSPACE" "$(sessions)" '["'$SESSION_ID'"]')"
expect "a reminder later today, with an offset" "keep: a reminder is set for 2026-10-26T17:00:00Z" \
  "$(verdict "$WORKSPACE" "$(sessions '{"labels":{"coord-parked-until":"2026-10-26T18:00:00+01:00"}}')" "$NO_CARDS")"
expect "a reminder for a bare date" "keep: a reminder is set for 2026-10-27T23:59:59Z" \
  "$(verdict "$WORKSPACE" "$(sessions '{"labels":{"coord-parked-until":"2026-10-27"}}')" "$NO_CARDS")"
expect "a reminder that has passed" "propose" \
  "$(verdict "$WORKSPACE" "$(sessions '{"labels":{"coord-parked-until":"2026-10-26T09:00:00+00:00"}}')" "$NO_CARDS")"
expect "an unreadable reminder" "keep: a reminder is set that cannot be read" \
  "$(verdict "$WORKSPACE" "$(sessions '{"labels":{"coord-parked-until":"soon"}}')" "$NO_CARDS")"
expect "activity 30 minutes ago" "keep: active 30 min ago" \
  "$(verdict "$WORKSPACE" "$(sessions '{"lastActivityAt":"2026-10-26T15:30:00.000Z"}')" "$NO_CARDS")"
expect "activity 70 minutes ago, past the 1 hour default" "propose" \
  "$(verdict "$WORKSPACE" "$(sessions '{"lastActivityAt":"2026-10-26T14:50:00.000Z"}')" "$NO_CARDS")"
expect "the human touched it 40 minutes ago" "keep: active 40 min ago" \
  "$(verdict "$WORKSPACE" "$(sessions '{"labels":{"coord-human-at":"2026-10-26T15:20:00Z"}}')" "$NO_CARDS")"
expect "a longer quiet period" "keep: active 70 min ago" \
  "$(quiet_hours=2 verdict "$WORKSPACE" "$(sessions '{"lastActivityAt":"2026-10-26T14:50:00.000Z"}')" "$NO_CARDS")"
expect "the default branch" "keep: not on a feature branch" \
  "$(verdict '{"id":"wks_test","cwd":"'$T/main'","title":"Main"}' "$(sessions)" "$NO_CARDS")"

PR_HEAD=""
expect "no merged pull request" "keep: no merged pull request" \
  "$(verdict "$WORKSPACE" "$(sessions)" "$NO_CARDS")"
PR_HEAD=$(git -C "$WT" rev-parse HEAD)

# --- What the worktree holds ---------------------------------------------------------------------

touch "$WT/notes.txt"
expect "an untracked file" "keep: uncommitted or untracked files" \
  "$(verdict "$WORKSPACE" "$(sessions)" "$NO_CARDS")"
quiet git -C "$WT" add notes.txt
expect "a staged file" "keep: uncommitted or untracked files" \
  "$(verdict "$WORKSPACE" "$(sessions)" "$NO_CARDS")"
quiet git -C "$WT" commit -m "after the merge"
expect "a commit made after the pull request, not pushed" "keep: commits not on origin or in the pull request" \
  "$(verdict "$WORKSPACE" "$(sessions)" "$NO_CARDS")"
quiet git -C "$WT" reset --hard "$PR_HEAD"
quiet git -C "$T/main" push origin --delete feature
quiet git -C "$WT" fetch --prune origin
expect "a squash merge deleted the remote branch; HEAD is the PR head" "propose" \
  "$(verdict "$WORKSPACE" "$(sessions)" "$NO_CARDS")"

# --- Proposing a card, never archiving ------------------------------------------------------------

session > "$COORD_RECORDS_DIR/proj/$SESSION_ID.json"
INBOX=$("$skill_dir/inbox.sh" path prj_1)

expect "a dry run reports the proposal" "🔑 Test stream | propose: close, PR #1 merged" "$(main prj_1)"
expect "a dry run adds no card" "absent" "$([[ -s $INBOX ]] && echo present || echo absent)"
expect "another project's scope sees nothing" "0" "$(main prj_2 | grep -c .)"

expect "--add adds one card" "added" "$(main prj_1 --add)"
expect "the card asks to close the session, with the PR" \
  "- [ ] 🔑 Test stream · accept · Close this session? Its [PR #1](https://github.com/o/r/pull/1) merged" \
  "$(grep -F "$SESSION_ID" "$INBOX")"
expect "it never archives" "absent" "$([[ -f $T/archived ]] && echo present || echo absent)"
expect "the open card keeps it off the next run" "0" "$(main prj_1 --add | grep -c .)"
expect "a run that proposes nothing still succeeds" "0" "$(main prj_1 --add > /dev/null; echo $?)"
"$skill_dir/inbox.sh" done prj_1 "$SESSION_ID" > /dev/null
expect "a session the human kept is not proposed again for the same PR" "skipped" "$(main prj_1 --add)"
expect "still one card" "1" "$(grep -c -F "$SESSION_ID" "$INBOX")"
expect "and still nothing archived" "absent" "$([[ -f $T/archived ]] && echo present || echo absent)"

AUTO_ARCHIVE_SETTING=true
expect "Paseo's own auto-archive being on is reported" "warning: Paseo's daemon.autoArchiveAfterMerge is on" \
  "$(main prj_1 2>&1 > /dev/null | head -1)"

printf '%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
