#!/usr/bin/env bash
# Runs one read-only sweep worker in a project's directory and prints its JSON report.
#
# Usage: sweep.sh <project-dir> <sessions-json-file>
#
# The worker skips user-level settings, so global hooks (finish notifications) stay quiet; the
# project's own settings and hooks still apply. Its tools allow reads only.

set -euo pipefail

project_dir=$1
sessions_file=$2
brief="$(dirname "$0")/sweep-worker.md"
claude_bin=$(command -v claude || echo "$HOME/.local/bin/claude")
accounts_script=$HOME/Projects/paseo-claude-accounts/scripts/claude-accounts.zsh

read_only_tools=(
  Read Grep Glob
  "Bash(paseo logs:*)"
  "Bash(gh pr view:*)" "Bash(gh pr checks:*)" "Bash(gh pr list:*)"
  "Bash(grep:*)" "Bash(tail:*)" "Bash(head:*)" "Bash(jq:*)"
)

compose_prompt() {
  cat "$brief"
  printf '\n## Sessions\n\n'
  cat "$sessions_file"
}

# Starts claude under the account the project declares, through the human's own account wrapper,
# so the rule lives in one place. Without the wrapper, claude runs on the default account.
claude_for_project() {
  if [[ -r $accounts_script ]]; then
    PATH="$(dirname "$claude_bin"):$PATH" zsh -c \
      'source "$1"; shift; print -u2 "sweep account: $(claude-account)"; claude "$@"' \
      _ "$accounts_script" "$@"
  else
    echo "sweep account: default (no account wrapper)" >&2
    "$claude_bin" "$@"
  fi
}

# The worker inherits nothing that names a session or account; the project decides the account.
run_worker() (
  unset PASEO_AGENT_ID PASEO_AGENT_CWD CLAUDE_CONFIG_DIR
  compose_prompt \
    | claude_for_project -p \
        --setting-sources project,local \
        --permission-mode default \
        --allowedTools "${read_only_tools[@]}" \
        --disallowedTools Edit Write NotebookEdit \
        --model sonnet \
        --effort medium \
        --no-session-persistence \
        --output-format json
)

# The worker may wrap its array in a code fence or prose; keep only the array, compacted.
report_or_error() {
  jq -r '
    if .is_error then "WORKER ERROR: \(.result)"
    else .result as $text
      | ($text | capture("(?s)(?<array>\\[.*\\])").array | fromjson | tojson)?
        // "WORKER BAD JSON: \($text)"
    end'
}

# On a subscription login this is usage against the plan's limits, priced at API rates; nothing is billed.
report_usage() {
  jq -r '"sweep usage for \($dir): $\(.total_cost_usd // "?") API-equivalent"' --arg dir "$project_dir" >&2
}

cd "$project_dir"

response=$(run_worker)
printf '%s' "$response" | report_usage
printf '%s' "$response" | report_or_error
