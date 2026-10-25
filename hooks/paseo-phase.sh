#!/bin/bash
# Prefixes the Paseo workspace title with the agent's current phase,
# e.g. "[Implementing] Auto labels", inferred from Claude Code hook events.
# A leading motif stays first: "🔑 [Implementing] Google sign-in".
#
# Phases: Planning, Implementing, Verifying, In review.
# Never blocks the agent: always exits 0, renames run in the background.
#
# PASEO_PHASE_DRY_RUN=1 prints the phase and title instead of renaming.

PHASES='Planning|Implementing|Verifying|In review'
STATE_DIR="${TMPDIR:-/tmp}/paseo-phase"

VERIFY_PATTERN='(^|[;&| ])((pnpm|npm|yarn|npx|bun)( -r| --filter [^ ]+)* (run )?(test|typecheck|lint|check)|vitest|jest|playwright test|tsc( |$)|mix (test|credo|dialyzer)|pytest|cargo test|go test|bash [^ ]*test)'
REVIEW_PATTERN='gh pr (create|ready)'

phase_for_tool() {
  local tool="$1" command="$2"
  case "$tool" in
    EnterPlanMode) echo "Planning" ;;
    Edit | Write | MultiEdit | NotebookEdit) echo "Implementing" ;;
    Bash)
      if [[ "$command" =~ $REVIEW_PATTERN ]]; then echo "In review"
      elif [[ "$command" =~ $VERIFY_PATTERN ]]; then echo "Verifying"
      fi ;;
  esac
}

phase_for_event() {
  local input="$1"
  local mode tool command
  mode=$(jq -r '.permission_mode // empty' <<<"$input")
  tool=$(jq -r '.tool_name // empty' <<<"$input")
  command=$(jq -r '.tool_input.command // empty' <<<"$input")

  if [[ "$mode" == "plan" ]]; then echo "Planning"
  else phase_for_tool "$tool" "$command"
  fi
}

# Paseo keeps each agent's record at $PASEO_HOME/agents/<cwd-slug>/<agent-id>.json.
# Undocumented, but the CLI does not expose an agent's workspace.
workspace_for_agent() {
  local record
  record=$(find "${PASEO_HOME:-$HOME/.paseo}/agents" -name "$1.json" -print -quit 2>/dev/null)
  [[ -n "$record" ]] && jq -r '.workspaceId // empty' "$record"
}

current_title() {
  "$PASEO_CLI" workspace ls --json 2>/dev/null |
    jq -r --arg id "$1" '.[] | select(.workspaceId == $id) | .name'
}

# A motif is a leading token of non-ASCII characters, usually one emoji, e.g. "🔑 Google sign-in".
# The coordinator skill writes it to mark a stream of work; it stays first, before the phase.
motif_of() {
  LC_ALL=C sed -nE 's/^([^ -~]+) .*/\1/p' <<<"$1"
}

without_motif() {
  LC_ALL=C sed -E 's/^[^ -~]+ //' <<<"$1"
}

strip_phase() {
  sed -E "s/^\[($PHASES)\] //" <<<"$1"
}

titled() {
  local motif
  motif=$(motif_of "$2")
  echo "${motif:+$motif }[$1] $(strip_phase "$(without_motif "$2")")"
}

already_set() {
  [[ "$(cat "$STATE_DIR/$1" 2>/dev/null)" == "$2" ]]
}

remember() {
  mkdir -p "$STATE_DIR" && echo "$2" >"$STATE_DIR/$1"
}

apply_phase() {
  local workspace="$1" phase="$2"
  local title new_title
  title=$(current_title "$workspace")
  [[ -z "$title" ]] && return
  new_title=$(titled "$phase" "$title")

  if [[ -n "$PASEO_PHASE_DRY_RUN" ]]; then echo "$phase | $new_title"
  elif [[ "$new_title" != "$title" ]]; then "$PASEO_CLI" workspace rename "$workspace" "$new_title" >/dev/null 2>&1
  fi
}

main() {
  [[ -z "$PASEO_AGENT_ID" || -z "$PASEO_CLI" ]] && return

  local phase workspace
  phase=$(phase_for_event "$(cat)")
  [[ -z "$phase" ]] && return

  workspace=$(workspace_for_agent "$PASEO_AGENT_ID")
  [[ -z "$workspace" ]] && return
  [[ -n "$PASEO_PHASE_DRY_RUN" ]] && apply_phase "$workspace" "$phase" && return
  already_set "$workspace" "$phase" && return

  remember "$workspace" "$phase"
  (apply_phase "$workspace" "$phase" &) >/dev/null 2>&1
}

main
exit 0
