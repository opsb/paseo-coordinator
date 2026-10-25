#!/usr/bin/env bash
# One tick of the coordinator's inbox worker. launchd runs it every minute (see tick-install.sh).
#
# For each coordinator session (label coord-role=coordinator) it:
#   1. adds a reminder card for each session whose coord-parked-until has passed;
#   2. finds the sessions in scope that have stopped and whose conversation changed since the last
#      tick, judged by a hash of the log tail, because label writes also move updatedAt;
#   3. has sweep workers read those, one per project, and adds a card for each that needs the human,
#      or a nudge card for the coordinator itself;
#   4. wakes the coordinator only if something new arrived, it is idle, and it is not waiting on the
#      human (its coord-card-open label is empty).
# A quiet tick starts no model, so it uses none of the plan's limits.
#
# Test knobs: COORD_STATE_ROOT, COORD_RECORDS_DIR, COORD_ID (serve this session as the coordinator),
# COORD_SCOPE, COORD_ONLY_IDS (space-separated session ids), COORD_ANYTIME=1 (ignore working hours),
# COORD_DRY_SEND=1 (log the wake instead of sending), COORD_ASSUME_IDLE=1.

set -uo pipefail
export PATH="/Applications/Paseo.app/Contents/Resources/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export LANG=${LANG:-en_GB.UTF-8}

skill_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
state_root=${COORD_STATE_ROOT:-$HOME/.local/state/coordinator}
records_dir=${COORD_RECORDS_DIR:-${PASEO_HOME:-$HOME/.paseo}/agents}
now=$(date -u +%FT%TZ)

log() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$state_root/tick.log"
}

in_working_hours() {
  [[ ${COORD_ANYTIME:-} == 1 ]] && return 0
  local hour
  hour=$(TZ=Europe/London date +%H)
  (( 10#$hour >= 8 && 10#$hour < 22 ))
}

# One tick at a time. A lock older than 15 minutes belongs to a tick that died.
take_tick_lock() {
  local lock=$state_root/.tick.lock
  if [[ -d $lock ]] && (( $(date +%s) - $(stat -f %m "$lock") > 900 )); then
    rmdir "$lock"
  fi
  mkdir "$lock" 2>/dev/null || return 1
  trap "rmdir '$lock'" EXIT
}

# --- Reading Paseo -------------------------------------------------------------------------------

live_records() {
  jq -c 'select(.archivedAt == null)' "$records_dir"/*/*.json
}

# The records are undocumented. Stop rather than guess if their shape changes.
records_look_right() {
  jq -n -e '[inputs | select(.archivedAt == null)]
    | length == 0 or (.[0] | has("id") and has("labels") and has("lastStatus") and has("updatedAt") and has("workspaceId"))' \
    "$records_dir"/*/*.json > /dev/null
}

coordinators() {
  live_records | jq -c --arg only "${COORD_ID:-}" --arg scope "${COORD_SCOPE:-}" '
    select(if $only != "" then .id == $only else .labels["coord-role"] == "coordinator" end)
    | {id, status: .lastStatus,
       scope: (if $scope != "" then $scope else (.labels["coord-scope"] // "all") end),
       card_open: ((.labels["coord-card-open"] // "") != "")}'
}

workspaces_by_id() {
  paseo workspace ls --json | jq -c 'map({key: .workspaceId, value: {title: .name, project}}) | from_entries'
}

projects_by_name() {
  paseo project ls --json | jq -c 'map({key: .name, value: {id: .projectId, dir: .path}}) | from_entries'
}

sessions_in_scope() {
  local scope=$1 coordinator_ids=$2 workspaces=$3 projects=$4
  live_records | jq -c --arg scope "$scope" --argjson coordinators "$coordinator_ids" \
      --argjson workspaces "$workspaces" --argjson projects "$projects" \
      --arg only "${COORD_ONLY_IDS:-}" '
    select(.internal != true)
    | select((.labels["paseo.schedule-id"] // "") == "")
    | select(.id as $id | $coordinators | index($id) | not)
    | select($only == "" or (.id as $id | $only | split(" ") | index($id)))
    | ($workspaces[.workspaceId // ""] // null) as $workspace
    | select($workspace != null)
    | ($projects[$workspace.project] // null) as $project
    | select($project != null and ($scope == "all" or $project.id == $scope))
    | {id, status: .lastStatus, updatedAt, createdAt, lastUserMessageAt, requiresAttention,
       attentionReason, labels: (.labels // {}), workspace_title: $workspace.title,
       project_dir: $project.dir}'
}

log_tail_hash() {
  paseo logs "$1" --filter text --tail 3 2>/dev/null | shasum | cut -c1-12
}

# --- Choosing what to read -----------------------------------------------------------------------

due_reminders() {
  jq -c --arg now "$now" '
    select((.labels["coord-parked-until"] // "") as $until | $until != "" and $until <= $now)'
}

# Stopped, not parked, and moved since the last tick. The log hash then rules out label-only moves.
moved_since_seen() {
  local seen=$1
  jq -c --arg now "$now" --slurpfile seen "$seen" '
    select(.status == "idle" or .status == "error")
    | select(.workspace_title | test("\\[parked\\]"; "i") | not)
    | select(((.labels["coord-parked-until"] // "") > $now) | not)
    | select(.updatedAt != ($seen[0][.id].updatedAt // ""))'
}

with_changed_conversation() {
  local seen=$1 session hash
  while read -r session; do
    hash=$(log_tail_hash "$(jq -r .id <<< "$session")")
    jq -c --arg hash "$hash" --slurpfile seen "$seen" '
      . + {hash: $hash, changed: ($hash != ($seen[0][.id].hash // ""))}' <<< "$session"
  done
}

remember_seen() {
  local seen=$1 updates=$2
  [[ -s $updates ]] || return 0
  jq -s --slurpfile seen "$seen" '
    reduce .[] as $s ($seen[0]; .[$s.id] = {updatedAt: $s.updatedAt, hash: $s.hash})' "$updates" \
    > "$seen.tmp" && mv "$seen.tmp" "$seen"
}

# --- Sweeping ------------------------------------------------------------------------------------

project_key() {
  printf '%s' "$1" | shasum | cut -c1-8
}

# The sessions this one has sent messages to, from its tool log. Creating a handoff agent doesn't count.
sent_to() {
  paseo logs "$1" --filter tools 2>/dev/null \
    | grep '^\[Send message\]' | grep -o '"agentId":"[^"]*"' | cut -d'"' -f4 \
    | grep -v -- "$1" | sort -u | jq -R . | jq -s -c .
}

# A session that has messaged other sessions is a relay: it never gets a card of its own.
with_relay_targets() {
  local session
  while read -r session; do
    jq -c --argjson sends "$(sent_to "$(jq -r .id <<< "$session")")" '. + {sends_to: $sends}' <<< "$session"
  done
}

sweep_input_for() {
  jq -c --arg dir "$2" 'select(.project_dir == $dir)
    | {id, workspace_title, status, createdAt, lastUserMessageAt, requiresAttention,
       attentionReason, labels, sends_to}' "$1" | jq -s .
}

# Runs one sweep worker per project, all at once, and leaves out-<key>.json beside each input.
sweep_projects() {
  local sessions=$1 work=$2 project_dir key
  while read -r project_dir; do
    key=$(project_key "$project_dir")
    sweep_input_for "$sessions" "$project_dir" > "$work/in-$key.json"
    "$skill_dir/sweep.sh" "$project_dir" "$work/in-$key.json" > "$work/out-$key.json" 2> "$work/err-$key.txt" &
  done < <(jq -r .project_dir "$sessions" | sort -u)
  wait
}

# Sweep usage this tick, priced at API rates. On a subscription it draws on plan limits, not a bill.
sweep_usage() {
  cat "$1"/err-*.txt 2>/dev/null | sed -n 's/^sweep usage for .*: \$\([0-9.]*\).*/\1/p' | awk '{s += $1} END {printf "%.2f", s}'
}

# One card per report entry that needs someone. Relays (listed in $2) get none. An entry whose ask
# is empty or says there is nothing to do is finished work: an Accept card asking to close the session.
cards_from_report() {
  local report=$1 relays=${2:-[]}
  jq -c --argjson relays "$relays" '
    def nothing_asked:
      (. // "") | ascii_downcase
      | test("^\\s*$") or test("^\\s*(none|n/a|nothing (required|needed|to do|pending)|no (action|further action)( needed| required)?)\\b");
    .[]
    | select(.class == "Blocked" or .class == "Ready" or .class == "Stuck")
    | select(.id as $id | $relays | index($id) | not)
    | if .class != "Stuck" and (.ask | nothing_asked) then
        {id, stream, kind: "accept",
         ask: "Close this session? \(if (.since | nothing_asked) then "It finished with nothing pending." else .since end)"}
      elif .class == "Stuck" then
        {id, stream, kind: "nudge", ask: (.nudge // .ask // "")}
      elif .class == "Ready" then
        {id, stream, kind: "accept", ask}
      else
        {id, stream, kind: (.kind // "decide"), ask}
      end' "$report"
}

# Records each outcome (added or skipped) in $adds_file, which serve sets per coordinator.
add_card() {
  local scope=$1 key=$2 id=$3 motif=$4 stream=$5 kind=$6 ask=$7
  "$skill_dir/inbox.sh" add "$scope" "$key" "$id" "$motif" "$stream" "$kind" "$ask" >> "$adds_file"
}

add_reminder_cards() {
  local scope=$1 session
  while read -r session; do
    add_card "$scope" \
      "$(jq -r '"\(.id)@remind@\(.labels["coord-parked-until"])"' <<< "$session")" \
      "$(jq -r .id <<< "$session")" \
      "$(jq -r '.labels["coord-motif"] // ""' <<< "$session")" \
      "$(jq -r '.labels["coord-gist"] // .workspace_title' <<< "$session")" \
      remind \
      "$(jq -r '"Reminder set for \(.labels["coord-parked-until"]). Next: \(.labels["coord-next"] // "see the session")"' <<< "$session")"
  done
}

added_count() {
  grep -c '^added$' "$adds_file" || true
}

# Adds a card per report entry that needs someone, and prints the sessions it read successfully.
cards_from_sweep() {
  local scope=$1 sessions=$2 work=$3 out card id
  for out in "$work"/out-*.json; do
    if ! jq -e 'type == "array"' "$out" > /dev/null 2>&1; then
      log "worker failed: $(head -c 200 "$out" | tr '\n' ' ')"
      continue
    fi
    while read -r card; do
      id=$(jq -r .id <<< "$card")
      add_card "$scope" \
        "$id@$(jq -r --arg id "$id" 'select(.id == $id) | .hash' "$sessions")" \
        "$id" \
        "$(jq -r --arg id "$id" 'select(.id == $id) | .labels["coord-motif"] // ""' "$sessions")" \
        "$(jq -r .stream <<< "$card")" \
        "$(jq -r .kind <<< "$card")" \
        "$(jq -r .ask <<< "$card")"
    done < <(cards_from_report "$out" "$(jq -s -c 'map(select((.sends_to // []) | length > 0) | .id)' "$sessions")")
    jq -r '.[].id' "$out" | while read -r id; do
      jq -c --arg id "$id" 'select(.id == $id)' "$sessions"
    done
  done
}

# --- Waking the coordinator ----------------------------------------------------------------------

open_card_count() {
  "$skill_dir/inbox.sh" open "$1" | wc -l | tr -d ' '
}

wake_message() {
  local scope=$1 new=$2
  printf '[coordinator inbox] %s new card(s). Run `%s/inbox.sh open %s`, rank the open cards as the skill says, show the human the next one and set coord-card-open.' \
    "$new" "$skill_dir" "$scope"
}

wake() {
  local id=$1 message=$2 dir=$3
  if [[ ${COORD_DRY_SEND:-} == 1 ]]; then
    printf '%s %s %s\n' "$(date '+%F %T')" "$id" "$message" >> "$dir/wakes.log"
  else
    paseo send "$id" --no-wait --behavior steer --prompt "$message" > /dev/null
  fi
}

# Wakes only when new cards wait, the human is not mid-card, and the coordinator is not mid-turn.
# A busy coordinator is retried next tick; one with a card open reads the inbox when it closes it.
decide_wake() {
  local coordinator=$1 scope=$2 dir=$3 new=$4
  local pending=$dir/wake-pending id status card_open
  id=$(jq -r .id <<< "$coordinator")
  status=$(jq -r .status <<< "$coordinator")
  card_open=$(jq -r .card_open <<< "$coordinator")
  [[ ${COORD_ASSUME_IDLE:-} == 1 ]] && status=idle
  (( new > 0 )) && echo "$new" > "$pending"
  [[ -f $pending ]] || { echo none; return; }
  if [[ $card_open == true ]]; then
    rm -f "$pending"; echo "held: card open"
  elif [[ $status == idle ]]; then
    wake "$id" "$(wake_message "$scope" "$(cat "$pending")")" "$dir"
    rm -f "$pending"; echo woken
  else
    echo "pending: coordinator $status"
  fi
}

# --- One coordinator -----------------------------------------------------------------------------

serve() {
  local coordinator=$1 coordinator_ids=$2 workspaces=$3 projects=$4
  local scope dir seen work new reminders swept wake_result
  scope=$(jq -r .scope <<< "$coordinator")
  dir=$state_root/$scope
  seen=$dir/seen.json
  work=$(mktemp -d)
  adds_file=$work/adds
  mkdir -p "$dir"
  touch "$adds_file"
  [[ -f $seen ]] || echo '{}' > "$seen"

  sessions_in_scope "$scope" "$coordinator_ids" "$workspaces" "$projects" > "$work/sessions.jsonl"
  reminders=$(due_reminders < "$work/sessions.jsonl" | tee "$work/reminders.jsonl" | wc -l | tr -d ' ')
  add_reminder_cards "$scope" < "$work/reminders.jsonl"

  moved_since_seen "$seen" < "$work/sessions.jsonl" | with_changed_conversation "$seen" > "$work/moved.jsonl"
  jq -c 'select(.changed | not)' "$work/moved.jsonl" > "$work/label-only.jsonl"
  jq -c 'select(.changed)' "$work/moved.jsonl" | with_relay_targets > "$work/changed.jsonl"
  remember_seen "$seen" "$work/label-only.jsonl"

  swept=$(wc -l < "$work/changed.jsonl" | tr -d ' ')
  if (( swept > 0 )); then
    sweep_projects "$work/changed.jsonl" "$work"
    cards_from_sweep "$scope" "$work/changed.jsonl" "$work" > "$work/read.jsonl"
    remember_seen "$seen" "$work/read.jsonl"
  fi

  new=$(added_count)
  wake_result=$(decide_wake "$coordinator" "$scope" "$dir" "$new")
  # Idle ticks leave no trace; log only a tick that read, added or woke something.
  if (( swept > 0 || new > 0 )) || [[ $wake_result != none ]]; then
    log "scope=$scope sessions=$(wc -l < "$work/sessions.jsonl" | tr -d ' ') label-only=$(wc -l < "$work/label-only.jsonl" | tr -d ' ') swept=$swept reminders=$reminders new=$new open=$(open_card_count "$scope") usage=\$$(sweep_usage "$work") wake=$wake_result"
  fi
  if [[ ${COORD_KEEP_WORK:-} == 1 ]]; then log "work kept in $work"; else rm -rf "$work"; fi
}

main() {
  mkdir -p "$state_root"
  in_working_hours || exit 0
  take_tick_lock || { log "skip: previous tick still running"; exit 0; }
  records_look_right || { log "error: Paseo agent records in $records_dir changed shape; tick stopped"; exit 1; }

  local workspaces projects coordinator_ids coordinator
  workspaces=$(workspaces_by_id) || { log "paseo workspace ls failed"; exit 1; }
  projects=$(projects_by_name) || { log "paseo project ls failed"; exit 1; }
  coordinator_ids=$(coordinators | jq -s -c 'map(.id)')

  while read -r coordinator; do
    serve "$coordinator" "$coordinator_ids" "$workspaces" "$projects"
  done < <(coordinators)
}

# Sourcing the file (for tests) defines the functions without running a tick.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
