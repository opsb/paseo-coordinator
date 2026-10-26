#!/usr/bin/env bash
# The coordinator's controls for the inbox worker: its working hours and the clock.
#
# Usage:
#   clock.sh status                          one line for the human
#   clock.sh on                              clock on: run now, whatever the hours, until clock off
#   clock.sh off [--until-clock-on]          clock off: pause until the working hours next begin,
#                                            or until the next clock on
#   clock.sh hours <HH:MM-HH:MM> [<zone>]    change the working hours, e.g. 07:30-23:00
#
# Every change records the worker's new state, so tick.sh announces only the changes the hours make
# on their own, never one the coordinator has just made.

set -euo pipefail

state_root=${COORD_STATE_ROOT:-$HOME/.local/state/coordinator}
source "$(dirname "${BASH_SOURCE[0]}")/schedule.sh"

job_label="com.$(id -un).coordinator-tick"

job_loaded() {
  launchctl print "gui/$(id -u)/$job_label" > /dev/null 2>&1
}

record_state() {
  local state
  state=$(worker_state "$(config)" "$(now_epoch)")
  echo "${state%% *}" > "$state_root/worker-state"
}

set_clock() {
  local mode=$1 until=$2
  write_config "$(config | jq -c --arg mode "$mode" --argjson since "$(now_epoch)" --argjson until "$until" \
    '.clock = {mode: $mode, since: $since, until: $until}')"
  record_state
}

valid_time() {
  [[ $1 =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ || $1 == 24:00 ]]
}

# A clock off that waits for the working hours moves with them.
set_hours() {
  local range=$1 zone=$2 start=${1%%-*} end=${1##*-} updated
  if ! valid_time "$start" || ! valid_time "$end" || [[ $range != *-* ]]; then
    echo "Hours must look like 08:00-22:00." >&2
    exit 2
  fi
  if [[ ! -f /usr/share/zoneinfo/$zone ]]; then
    echo "Unknown time zone: $zone" >&2
    exit 2
  fi
  updated=$(config | jq -c --arg start "$start" --arg end "$end" --arg zone "$zone" \
    '.hours = {start: $start, end: $end, timezone: $zone}')
  if [[ $(jq -r '.clock.mode' <<< "$updated") == off && -n $(jq -r '.clock.until // empty' <<< "$updated") ]]; then
    updated=$(jq -c --argjson until "$(next_start_epoch "$updated" "$(now_epoch)")" '.clock.until = $until' <<< "$updated")
  fi
  write_config "$updated"
  record_state
}

status_line() {
  if [[ ${COORD_SKIP_JOB_CHECK:-} != 1 ]] && ! job_loaded; then
    echo "Inbox worker: not installed; run tick-install.sh to start it."
    return
  fi
  echo "Inbox worker: $(describe_worker "$(config)" "$(now_epoch)")."
}

main() {
  mkdir -p "$state_root"
  case ${1:-status} in
    status) ;;
    on) set_clock on null ;;
    off)
      if [[ ${2:-} == --until-clock-on ]]; then
        set_clock off null
      else
        set_clock off "$(next_start_epoch "$(config)" "$(now_epoch)")"
      fi
      ;;
    hours) set_hours "${2:?usage: clock.sh hours HH:MM-HH:MM [zone]}" "${3:-$(hours_field "$(config)" timezone)}" ;;
    *) echo "usage: clock.sh status | on | off [--until-clock-on] | hours HH:MM-HH:MM [zone]" >&2; exit 2 ;;
  esac
  status_line
}

main "$@"
