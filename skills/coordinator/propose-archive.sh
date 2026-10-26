#!/usr/bin/env bash
# Proposes closing sessions whose work is over. It never archives anything: for each session that
# looks finished it adds an `accept` card, "Close this session?", to the coordinator's inbox, and the
# coordinator archives only what the human confirms. Paseo's own daemon.autoArchiveAfterMerge must
# stay off, because it archives the moment a PR merges, even mid-release.
#
# A workspace's sessions are proposed only when all of these hold; anything it cannot check keeps
# them off the list:
#   1. its checkout is on a branch other than the repository's default branch;
#   2. it has live sessions, none of them a coordinator, running, or waiting for attention;
#   3. none has an open inbox card or a reminder still to come;
#   4. nothing has happened in it, and the human has not touched it, for COORD_CLOSE_AFTER_HOURS
#      (default 1);
#   5. its worktree has no uncommitted or untracked files, and every commit is on origin or is the
#      merged pull request's head;
#   6. its branch's pull request has merged.
# Check 5 matters because archiving a workspace's last session archives the workspace too, and
# Paseo then deletes its worktree with `git worktree remove --force`.
#
# Usage: propose-archive.sh <scope> [--add]
#   <scope> is `all` or a Paseo projectId. Without --add it prints each decision and changes nothing.
#   With --add it adds the cards and prints inbox.sh's added or skipped for each, which tick.sh
#   counts. A card's key holds the PR, so a session the human kept is not proposed again for it.
# tick.sh runs it with --add once an hour for each coordinator while the worker is on.
#
# Test knobs: COORD_STATE_ROOT, COORD_RECORDS_DIR, COORD_NOW (epoch seconds),
# COORD_CLOSE_AFTER_HOURS. Sourcing the file defines the functions without running it.

set -uo pipefail
export PATH="/Applications/Paseo.app/Contents/Resources/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
export LANG=${LANG:-en_GB.UTF-8}

skill_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
state_root=${COORD_STATE_ROOT:-$HOME/.local/state/coordinator}
records_dir=${COORD_RECORDS_DIR:-${PASEO_HOME:-$HOME/.paseo}/agents}
quiet_hours=${COORD_CLOSE_AFTER_HOURS:-1}

source "$skill_dir/schedule.sh"

# --- Reading Paseo -------------------------------------------------------------------------------

active_workspaces() {
  local scope=$1
  jq -n -c --arg scope "$scope" \
      --argjson projects "$(paseo project ls --json)" --argjson workspaces "$(paseo workspace ls --json)" '
    ($projects | map({key: .name, value: .projectId}) | from_entries) as $project_ids
    | $workspaces[]
    | select($scope == "all" or $project_ids[.project] == $scope)
    | {id: .workspaceId, cwd, title: .name}'
}

# Every live session a person runs, as one array, so checking a workspace reads nothing more.
live_sessions() {
  jq -s -c 'map(select(.archivedAt == null and .internal != true
    and (.labels["paseo.schedule-id"] // "") == ""))' "$records_dir"/*/*.json
}

# Session ids that hold an open card in any inbox: those still need the human.
open_card_ids() {
  cat "$state_root"/*/inbox.md 2> /dev/null |
    grep '^- \[ \]' |
    grep -o -E '[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}' |
    jq -R . | jq -s -c 'unique'
}

paseo_archives_on_merge() {
  [[ $(paseo daemon config get daemon.autoArchiveAfterMerge 2> /dev/null | jq -r '.value // false') == true ]]
}

# --- The checks ----------------------------------------------------------------------------------

# The checkout's branch, if it is one other than the repository's default.
feature_branch() {
  local cwd=$1 branch default
  branch=$(git -C "$cwd" branch --show-current 2> /dev/null)
  [[ -n $branch ]] || return 0
  default=$(git -C "$cwd" symbolic-ref --short refs/remotes/origin/HEAD 2> /dev/null)
  default=${default#origin/}
  [[ $branch == "${default:-main}" || $branch == main || $branch == master ]] && return 0
  echo "$branch"
}

# Why the workspace's sessions say keep, or nothing when every one is finished and quiet. Times
# are ISO strings with or without fractions or an offset; a bare date counts as the end of that day.
sessions_say_keep() {
  local workspace_id=$1 sessions=$2 open_ids=$3
  jq -r --arg w "$workspace_id" --argjson open "$open_ids" \
    --argjson now "$(now_epoch)" --argjson quiet "$((quiet_hours * 3600))" '
    def offset_seconds: capture("(?<sign>[+-])(?<h>[0-9]{2}):?(?<m>[0-9]{2})")
      | ((.h | tonumber) * 3600 + (.m | tonumber) * 60) * (if .sign == "-" then -1 else 1 end);
    def epoch:
      if . == null or . == "" then null
      else (if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") then . + "T23:59:59Z" else . end | sub("\\.[0-9]+"; "")) as $s
        | if $s | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:?[0-9]{2})?$")
          then (($s[0:19] + "Z") | fromdateiso8601) - ($s[19:] | if . == "" or . == "Z" then 0 else offset_seconds end)
          else "unreadable" end
      end;
    def ago: ([.,0] | max) as $s | if $s < 7200 then "\($s / 60 | floor) min ago" else "\($s / 3600 | floor)h ago" end;
    map(select(.workspaceId == $w)) as $mine
    | ($mine | map(select(.labels["coord-role"] == "coordinator")) | first) as $coordinator
    | ($mine | map(select(.lastStatus != "idle" and .lastStatus != "closed")) | first) as $busy
    | ($mine | map(select(.requiresAttention == true)) | first) as $asking
    | ($mine | map(select(.id as $id | $open | index($id))) | first) as $carded
    | ($mine | map(.labels["coord-parked-until"] | epoch | select(. != null))
        | map(select(. == "unreadable" or . > $now)) | first) as $reminder
    | ($mine | map(.lastActivityAt, .lastUserMessageAt, .labels["coord-human-at"])
        | map(epoch | numbers) | max) as $last
    | if ($mine | length) == 0 then "no live sessions"
      elif $coordinator then "the coordinator works here"
      elif $busy then "a session is \($busy.lastStatus)"
      elif $asking then "a session is waiting for attention"
      elif $carded then "a session has an open inbox card"
      elif $reminder == "unreadable" then "a reminder is set that cannot be read"
      elif $reminder then "a reminder is set for \($reminder | todate)"
      elif $last != null and ($now - $last) < $quiet then "active \($now - $last | ago)"
      else empty end' <<< "$sessions"
}

# Uncommitted or untracked files, which Paseo's forced removal would destroy. A worktree git cannot
# read counts as changed.
has_local_changes() {
  local changes
  changes=$(git -C "$1" status --porcelain --untracked-files=all 2> /dev/null) || return 0
  [[ -n $changes ]]
}

# Commits on the branch that are neither on origin nor the merged pull request's head. Squash
# merges usually delete the remote branch, so the PR head is what proves the work went in.
has_unshared_commits() {
  local cwd=$1 pr_head=$2 head unshared
  head=$(git -C "$cwd" rev-parse HEAD 2> /dev/null) || return 0
  [[ $head == "$pr_head" ]] && return 1
  unshared=$(git -C "$cwd" rev-list -1 HEAD --not --remotes=origin 2> /dev/null) || return 0
  [[ -n $unshared ]]
}

# The merged pull request for the branch as {url, number, headRefOid}, or nothing.
merged_pr() {
  local cwd=$1 branch=$2
  (cd "$cwd" && gh pr list --head "$branch" --state merged --json url,number,headRefOid --limit 1 2> /dev/null) |
    jq -c '.[0] // empty' 2> /dev/null
}

# "propose <pr-json>" or "keep: <reason>". The cheap checks go first, so GitHub is asked last.
verdict() {
  local workspace=$1 sessions=$2 open_ids=$3 id cwd branch reason pr
  id=$(jq -r .id <<< "$workspace")
  cwd=$(jq -r .cwd <<< "$workspace")
  branch=$(feature_branch "$cwd")
  [[ -n $branch ]] || { echo "keep: not on a feature branch"; return; }
  reason=$(sessions_say_keep "$id" "$sessions" "$open_ids")
  [[ -z $reason ]] || { echo "keep: $reason"; return; }
  has_local_changes "$cwd" && { echo "keep: uncommitted or untracked files, or an unreadable worktree"; return; }
  pr=$(merged_pr "$cwd" "$branch")
  [[ -n $pr ]] || { echo "keep: no merged pull request"; return; }
  has_unshared_commits "$cwd" "$(jq -r .headRefOid <<< "$pr")" && { echo "keep: commits not on origin or in the pull request"; return; }
  echo "propose $pr"
}

# --- Proposing -----------------------------------------------------------------------------------

# One accept card per live session in the workspace. The motif and stream come from the title.
propose() {
  local scope=$1 workspace=$2 sessions=$3 pr=$4 session
  jq -c --argjson workspace "$workspace" --argjson pr "$pr" '
    ($workspace.title | capture("^(?<motif>[^\\x00-\\x7F]+) (?<name>.*)$") // {motif: "", name: .}) as $title
    | .[] | select(.workspaceId == $workspace.id)
    | {id, key: "\(.id)@close@\($pr.url)", motif: (.labels["coord-motif"] // $title.motif), stream: $title.name,
       ask: "Close this session? Its [PR #\($pr.number)](\($pr.url)) merged; nothing is running or waiting, and its worktree is clean and pushed."}' \
    <<< "$sessions" |
    while read -r session; do
      "$skill_dir/inbox.sh" add "$scope" \
        "$(jq -r .key <<< "$session")" "$(jq -r .id <<< "$session")" "$(jq -r .motif <<< "$session")" \
        "$(jq -r .stream <<< "$session")" accept "$(jq -r .ask <<< "$session")"
    done
}

describe() {
  local decision=$1
  if [[ $decision == propose* ]]; then
    echo "propose: close, PR #$(jq -r .number <<< "${decision#propose }") merged"
  else
    echo "$decision"
  fi
}

main() {
  local scope=${1:?usage: propose-archive.sh <scope> [--add]} add=${2:-} sessions open_ids workspace decision
  if paseo_archives_on_merge; then
    echo "warning: Paseo's daemon.autoArchiveAfterMerge is on and archives on merge without asking; turn it off with: paseo daemon config set daemon.autoArchiveAfterMerge false && paseo daemon reload" >&2
  fi
  sessions=$(live_sessions)
  open_ids=$(open_card_ids)
  while read -r workspace; do
    decision=$(verdict "$workspace" "$sessions" "$open_ids")
    if [[ $add == --add ]]; then
      if [[ $decision == propose* ]]; then
        propose "$scope" "$workspace" "$sessions" "${decision#propose }"
      fi
    else
      printf '%s | %s\n' "$(jq -r .title <<< "$workspace")" "$(describe "$decision")"
    fi
  done < <(active_workspaces "$scope")
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
