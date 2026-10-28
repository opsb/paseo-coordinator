#!/usr/bin/env bash
# The coordinator's card inbox: one markdown line per card, and at most one open card per session.
# The tick worker adds cards, replaces a session's card when its conversation moves on, and ticks off
# cards whose session no longer waits; the coordinator ticks off the cards it closes. Every change
# takes the same lock, so neither loses the other's. The file is an inbox, not an order: the
# coordinator ranks open cards itself.
#
# add prints what it did: added, replaced (the session's open card was ticked off and this one
# appended) or skipped (a card with this key exists, or a reminder for a session that already has an
# open card).
#
# Usage:
#   inbox.sh path <scope>
#   inbox.sh add  <scope> <key> <session-id> <motif> <stream> <kind> <ask>
#   inbox.sh open <scope>
#   inbox.sh done <scope> <session-id>
#
# <scope> is `all` or a Paseo projectId. A card line reads:
#   - [ ] 🔑 Google sign-in · do · Run the gate sync · <session-id> · 2026-10-25 18:52 <!-- <key> -->

set -euo pipefail

state_root=${COORD_STATE_ROOT:-$HOME/.local/state/coordinator}

inbox_path() {
  echo "$state_root/$1/inbox.md"
}

ensure_inbox() {
  local inbox=$1
  [[ -f $inbox ]] && return
  mkdir -p "$(dirname "$inbox")"
  printf '# Coordinator inbox\n\nOne line per card, in arrival order. The tick worker adds; the coordinator ticks off.\n\n' > "$inbox"
}

lock_inbox() {
  local lock="$1.lock"
  until mkdir "$lock" 2>/dev/null; do sleep 0.1; done
  trap "rmdir '$lock'" EXIT
}

single_line() {
  tr '\n\r' '  ' <<< "$1" | sed 's/  */ /g; s/ *$//'
}

has_key() {
  grep -qF -- "<!-- $2 -->" "$1"
}

has_open_card_for() {
  grep -q -- "^- \[ \] .* · $2 · " "$1"
}

card_line() {
  local key=$1 session_id=$2 motif=$3 stream=$4 kind=$5 ask=$6
  printf -- '- [ ] %s · %s · %s · %s · %s <!-- %s -->\n' \
    "$(single_line "${motif:+$motif }$stream")" "$kind" "$(single_line "$ask")" \
    "$session_id" "$(date '+%Y-%m-%d %H:%M')" "$key"
}

# A new key for a session that already has an open card means its conversation moved on: the old ask
# is out of date, so the new card takes its place. A reminder never displaces a card; the open card
# already brings the stream back.
add_card() {
  local inbox=$1 key=$2 session_id=$3 kind=$6
  if has_key "$inbox" "$key"; then
    echo skipped
  elif ! has_open_card_for "$inbox" "$session_id"; then
    card_line "${@:2}" >> "$inbox"
    echo added
  elif [[ $kind == remind ]]; then
    echo skipped
  else
    tick_off "$inbox" "$session_id"
    card_line "${@:2}" >> "$inbox"
    echo replaced
  fi
}

open_cards() {
  grep -- '^- \[ \] ' "$1" || true
}

tick_off() {
  local inbox=$1 session_id=$2
  sed -i '' "s/^- \[ \] \(.* · $session_id · .*\)$/- [x] \1/" "$inbox"
}

main() {
  local command=$1 scope=$2
  local inbox
  inbox=$(inbox_path "$scope")
  case $command in
    path) echo "$inbox" ;;
    open) [[ -f $inbox ]] && open_cards "$inbox" || true ;;
    add)
      ensure_inbox "$inbox"
      lock_inbox "$inbox"
      add_card "$inbox" "${@:3}"
      ;;
    done)
      [[ -f $inbox ]] || exit 0
      lock_inbox "$inbox"
      tick_off "$inbox" "$3"
      ;;
    *) echo "usage: inbox.sh path|add|open|done <scope> ..." >&2; exit 2 ;;
  esac
}

main "$@"
