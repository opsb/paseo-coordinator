#!/usr/bin/env bash
# Checks that cards stay current: inbox.sh replaces a session's card when its conversation moves on,
# and tick.sh ticks off cards whose session no longer waits and clears due reminders. Uses a
# throwaway state root and session records, and writes no labels. Run: bash inbox.test.sh
set -uo pipefail

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export COORD_STATE_ROOT=$T/state COORD_RECORDS_DIR=$T/agents COORD_DRY_SEND=1
mkdir -p "$COORD_STATE_ROOT" "$COORD_RECORDS_DIR/proj"
here=$(cd "$(dirname "$0")" && pwd)
inbox() { "$here/inbox.sh" "$@"; }
source "$here/tick.sh"

pass=0
fail=0

expect() {
  local name=$1 expected=$2 actual=$3
  if [[ $actual == "$expected" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$name" "$expected" "$actual"
  fi
}

A=aaaaaaaa-0000-0000-0000-000000000001
B=bbbbbbbb-0000-0000-0000-000000000002

open_for() { inbox open all | grep -c -- " · $1 · " || true; }
open_ask_for() { inbox open all | grep -- " · $1 · " | cut -d'·' -f3 | sed 's/^ //; s/ $//'; }
log_has() { grep -c -F -- "$1" "$COORD_STATE_ROOT/tick.log" || true; }

# A session record; each case passes the fields it changes.
record() {
  jq -n -c --arg id "$1" --argjson extra "${2:-{\}}" \
    '{id: $id, archivedAt: null, lastStatus: "idle", lastUserMessageAt: null, labels: {}} * $extra' \
    > "$COORD_RECORDS_DIR/proj/$1.json"
}

# --- inbox.sh add --------------------------------------------------------------------------------

expect "a first card is added" added "$(inbox add all "$A@h1" "$A" "" Stream decide "Approve proposal 1?")"
expect "the same key is skipped" skipped "$(inbox add all "$A@h1" "$A" "" Stream decide "Approve proposal 1?")"
expect "a new key replaces the open card" replaced \
  "$(inbox add all "$A@h2" "$A" "" Stream decide "Approve proposal 2?")"
expect "one open card per session" 1 "$(open_for "$A")"
expect "the open card holds the new ask" "Approve proposal 2?" "$(open_ask_for "$A")"
expect "the replaced card is ticked off" 1 "$(grep -c -F -- '- [x] Stream · decide · Approve proposal 1?' "$(inbox path all)")"
expect "a reminder does not displace an open card" skipped \
  "$(inbox add all "$A@remind@t" "$A" "" Stream remind "Reminder set")"
expect "the open card survives the reminder" "Approve proposal 2?" "$(open_ask_for "$A")"
expect "an old key does not return once ticked off" skipped \
  "$(inbox add all "$A@h1" "$A" "" Stream decide "Approve proposal 1?")"

# --- tick.sh: closing cards whose session no longer waits ----------------------------------------

added=$(date -j -f '%Y-%m-%d %H:%M' '2026-10-28 11:00' +%s)
records() { records_by_id; }
SEEN=$T/seen.json
echo '{}' > "$SEEN"

record "$A"
expect "an idle session's card stands" "" "$(stale_reason "$A" "$added" "$A@h1" "$(records)" "$SEEN")"
record "$A" '{"lastUserMessageAt": "2026-10-28T11:00:30.000Z"}'
expect "a message within the card's minute is not an answer" "" "$(stale_reason "$A" "$added" "$A@h1" "$(records)" "$SEEN")"
record "$A" "{\"lastUserMessageAt\": \"$(date -u -r $((added + 120)) +%FT%T).000Z\"}"
expect "a later message answers the card" answered "$(stale_reason "$A" "$added" "$A@h1" "$(records)" "$SEEN")"
record "$A" '{"lastStatus": "running"}'
expect "a running session's card is closed" running "$(stale_reason "$A" "$added" "$A@h1" "$(records)" "$SEEN")"
record "$A" '{"archivedAt": "2026-10-28T12:00:00.000Z", "lastStatus": "closed"}'
expect "an archived session's card is closed" archived "$(stale_reason "$A" "$added" "$A@h1" "$(records)" "$SEEN")"
expect "a session with no record is gone" gone "$(stale_reason "$B" "$added" "$B@h1" "$(records)" "$SEEN")"

record "$B"
echo "{\"$B\": {\"hash\": \"222222222222\"}}" > "$SEEN"
expect "a sweep card the sweep has read past is overtaken" overtaken \
  "$(stale_reason "$B" "$added" "$B@111111111111" "$(records)" "$SEEN")"
expect "a sweep card for the last read stands" "" \
  "$(stale_reason "$B" "$added" "$B@222222222222" "$(records)" "$SEEN")"
expect "a reminder card is never overtaken" "" \
  "$(stale_reason "$B" "$added" "$B@remind@2026-10-28T09:00:00+00:00" "$(records)" "$SEEN")"
echo "{\"$A\": {\"hash\": \"333333333333\"}, \"$B\": {\"hash\": \"222222222222\"}}" > "$SEEN"

record "$A" '{"lastStatus": "running"}'
record "$B"
inbox add all "$B@h1" "$B" "" Other do "Run the gate" > /dev/null
expect "close_stale_cards ticks off only the stale card" "$A" "$(close_stale_cards all "$SEEN")"
expect "the stale card is gone" 0 "$(open_for "$A")"
expect "the standing card stays" 1 "$(open_for "$B")"
expect "the close is logged with its reason" 1 "$(log_has "card closed: $A running")"
expect "the closed session is forgotten, so the sweep reads it again" "[\"$B\"]" "$(jq -c 'keys' "$SEEN")"

# --- tick.sh: reminders --------------------------------------------------------------------------

adds_file=$T/adds
touch "$adds_file"
jq -n -c --arg id "$B" '{id: $id, workspace_title: "Other",
  labels: {"coord-parked-until": "2026-10-28T09:00:00+00:00"}}' | add_reminder_cards all
expect "a reminder for a session with an open card adds nothing" 0 "$(added_count)"
expect "the skip is logged" 1 "$(log_has "card skipped: $B remind")"
expect "the due reminder's label is cleared" 1 "$(log_has "dry: label coord-parked-until= on $B")"

# --- inbox.sh keep and report: the worker's full report behind each card --------------------------

C=cccccccc-0000-0000-0000-000000000003
report_ask() { inbox report all "$1" | jq -r '.ask // empty'; }

inbox add all "$C@h1" "$C" "" Third decide "Ship it?" > /dev/null
echo '{"id": "x", "ask": "Ship it?", "recommend": "yes"}' | inbox keep all "$C@h1" "$C"
expect "the report for the open card is shown" "Ship it?" "$(report_ask "$C")"
expect "the report carries the card's key" "$C@h1" "$(inbox report all "$C" | jq -r .key)"
echo '{"ask": "Old ask"}' | inbox keep all "$C@h0" "$C"
expect "a report for another key is not shown" "" "$(report_ask "$C")"
echo '{"ask": "Ship it?"}' | inbox keep all "$C@h1" "$C"
inbox done all "$C"
expect "a closed card has no report" "" "$(report_ask "$C")"
expect "closing a card removes its report" 0 "$(ls "$COORD_STATE_ROOT/all/reports" | grep -c "$C" || true)"
expect "a session never reported has none" "" "$(report_ask "$B")"

# --- tick.sh: sweep cards keep their reports -----------------------------------------------------

D=dddddddd-0000-0000-0000-000000000004
W=$T/work
mkdir -p "$W"
jq -n -c --arg id "$D" '{id: $id, hash: "444444444444", labels: {}}' > "$W/sessions.jsonl"
jq -n --arg id "$D" '[{id: $id, stream: "Fourth", class: "Blocked", kind: "decide", ask: "Merge now?",
  recommend: "yes, CI is green", links: [{label: "PR #1", url: "https://github.com/a/b/pull/1", state: "approved"}]}]' \
  > "$W/out-proj.json"
cards_from_sweep all "$W/sessions.jsonl" "$W" > /dev/null
expect "a sweep card is added" 1 "$(open_for "$D")"
expect "its report is kept" "yes, CI is green" "$(inbox report all "$D" | jq -r .recommend)"
expect "the report keeps the links" "https://github.com/a/b/pull/1" "$(inbox report all "$D" | jq -r '.links[0].url')"

printf '%s passed, %s failed\n' "$pass" "$fail"
(( fail == 0 ))
