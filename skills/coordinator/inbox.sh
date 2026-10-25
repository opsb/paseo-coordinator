#!/usr/bin/env bash
# The coordinator's card inbox: one markdown line per card. The tick worker only adds cards; the
# coordinator only ticks them off. Every change takes the same lock, so neither loses the other's.
# The file is an inbox, not an order: the coordinator ranks open cards itself.
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

has_card_for() {
  local inbox=$1 key=$2 session_id=$3
  grep -qF -- "<!-- $key -->" "$inbox" || grep -q -- "^- \[ \] .* · $session_id · " "$inbox"
}

add_card() {
  local inbox=$1 key=$2 session_id=$3 motif=$4 stream=$5 kind=$6 ask=$7
  if has_card_for "$inbox" "$key" "$session_id"; then
    echo skipped
    return
  fi
  printf -- '- [ ] %s · %s · %s · %s · %s <!-- %s -->\n' \
    "$(single_line "${motif:+$motif }$stream")" "$kind" "$(single_line "$ask")" \
    "$session_id" "$(date '+%Y-%m-%d %H:%M')" "$key" >> "$inbox"
  echo added
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
