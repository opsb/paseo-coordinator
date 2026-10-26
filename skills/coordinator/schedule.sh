# Working hours and the clock for the inbox worker. Sourced by tick.sh and clock.sh; expects
# $state_root to be set.
#
# $state_root/config.json is written only by clock.sh:
#   {"hours": {"start": "08:00", "end": "22:00", "timezone": "Europe/London"},
#    "clock": {"mode": "auto" | "on" | "off", "since": <epoch>, "until": <epoch> | null}}
#
# auto follows the hours. on runs regardless of them until a clock off. off pauses until `until`,
# or until the next clock on when `until` is null; after `until` passes, auto takes over again.
# COORD_NOW (epoch seconds) stands in for the current time in tests; COORD_ANYTIME=1 keeps it on.

config_file() {
  echo "$state_root/config.json"
}

config() {
  local file
  file=$(config_file)
  { [[ -f $file ]] && cat "$file" || echo '{}'; } | jq -c '
    {hours: ({start: "08:00", end: "22:00", timezone: "Europe/London"} + (.hours // {})),
     clock: ({mode: "auto", since: null, until: null} + (.clock // {}))}'
}

write_config() {
  local file
  file=$(config_file)
  mkdir -p "$state_root"
  jq . <<< "$1" > "$file.tmp" && mv "$file.tmp" "$file"
}

now_epoch() {
  echo "${COORD_NOW:-$(date +%s)}"
}

minutes_of() {
  local hours=${1%%:*} minutes=${1##*:}
  echo $(( 10#$hours * 60 + 10#$minutes ))
}

hours_field() {
  jq -r ".hours.$2" <<< "$1"
}

local_time() {
  TZ=$2 date -r "$1" "${3:-+%H:%M}"
}

# Start equal to end means always on; start after end spans midnight.
within_hours() {
  local config=$1 now=$2 start end tz at
  start=$(minutes_of "$(hours_field "$config" start)")
  end=$(minutes_of "$(hours_field "$config" end)")
  tz=$(hours_field "$config" timezone)
  at=$(minutes_of "$(local_time "$now" "$tz")")
  if (( start == end )); then
    return 0
  elif (( start < end )); then
    (( at >= start && at < end ))
  else
    (( at >= start || at < end ))
  fi
}

# The next moment, after now, at which the working hours begin.
next_start_epoch() {
  local config=$1 now=$2 tz start today candidate
  tz=$(hours_field "$config" timezone)
  start=$(hours_field "$config" start)
  today=$(local_time "$now" "$tz" +%Y-%m-%d)
  candidate=$(TZ=$tz date -j -f '%Y-%m-%d %H:%M:%S' "$today $start:00" +%s)
  if (( candidate <= now )); then
    candidate=$(TZ=$tz date -j -v+1d -f '%Y-%m-%d %H:%M:%S' "$today $start:00" +%s)
  fi
  echo "$candidate"
}

# Prints "on" or "off", then the reason: hours, clock or anytime.
worker_state() {
  local config=$1 now=$2 mode until
  mode=$(jq -r .clock.mode <<< "$config")
  until=$(jq -r '.clock.until // empty' <<< "$config")
  if [[ ${COORD_ANYTIME:-} == 1 ]]; then
    echo "on anytime"
  elif [[ $mode == on ]]; then
    echo "on clock"
  elif [[ $mode == off ]] && { [[ -z $until ]] || (( until > now )); }; then
    echo "off clock"
  elif within_hours "$config" "$now"; then
    echo "on hours"
  else
    echo "off hours"
  fi
}

# "08:00 today", "08:00 tomorrow" or "08:00 Tuesday", in the hours' time zone.
when_text() {
  local at=$1 now=$2 tz=$3 day
  if [[ $(local_time "$at" "$tz" +%F) == $(local_time "$now" "$tz" +%F) ]]; then
    day=today
  elif [[ $(local_time "$at" "$tz" +%F) == $(TZ=$tz date -r "$now" -v+1d +%F) ]]; then
    day=tomorrow
  else
    day=$(local_time "$at" "$tz" +%A)
  fi
  echo "$(local_time "$at" "$tz") $day"
}

# One line for the human: whether the worker is on, why, and when that changes.
describe_worker() {
  local config=$1 now=$2 state tz hours
  state=$(worker_state "$config" "$now")
  tz=$(hours_field "$config" timezone)
  hours="$(hours_field "$config" start)–$(hours_field "$config" end) ${tz##*/} time"
  case $state in
    "on anytime") echo "on, at all hours (COORD_ANYTIME)" ;;
    "on clock") echo "on, clocked on; it runs until you clock off (working hours $hours)" ;;
    "on hours") echo "on, working hours $hours; it goes off at $(hours_field "$config" end)" ;;
    "off clock")
      if [[ -z $(jq -r '.clock.until // empty' <<< "$config") ]]; then
        echo "off, clocked off; it starts again when you clock on"
      else
        echo "off, clocked off; it starts again at $(when_text "$(jq -r .clock.until <<< "$config")" "$now" "$tz")"
      fi
      ;;
    "off hours") echo "off, outside working hours $hours; it starts again at $(when_text "$(next_start_epoch "$config" "$now")" "$now" "$tz")" ;;
  esac
}
