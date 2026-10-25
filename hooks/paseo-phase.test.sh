#!/bin/bash
# Checks how paseo-phase.sh builds titles, motif included. Loads the hook's functions without running main.
HOOK="$(dirname "$0")/paseo-phase.sh"
source <(sed -e '/^main$/d' -e '/^exit 0$/d' "$HOOK")

failures=0

expect_title() {
  local phase="$1" title="$2" expected="$3" actual
  actual=$(titled "$phase" "$title")
  if [[ "$actual" == "$expected" ]]; then
    echo "ok    $title  ->  $actual"
  else
    echo "FAIL  $title  ->  $actual  (expected: $expected)"
    failures=$((failures + 1))
  fi
}

expect_title Implementing "Manager skill" "[Implementing] Manager skill"
expect_title Verifying "[Implementing] Manager skill" "[Verifying] Manager skill"
expect_title Planning "🔑 Google sign-in" "🔑 [Planning] Google sign-in"
expect_title "In review" "🔑 [Implementing] Google sign-in" "🔑 [In review] Google sign-in"
expect_title Verifying "⚙️ [Planning] Settings page" "⚙️ [Verifying] Settings page"
expect_title Planning "🏳️‍🌈 Pride banner" "🏳️‍🌈 [Planning] Pride banner"
expect_title Planning "Über cool" "[Planning] Über cool"
expect_title Planning "🔑 [parked] Google sign-in" "🔑 [Planning] [parked] Google sign-in"

echo "$failures failure(s)"
exit "$failures"
