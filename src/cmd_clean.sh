cmd_clean() {
  local AGENTS_DIR="$HOME/.claude/agents"
  local SKILLS_DIR="$HOME/.claude/skills"
  local AGENTS_DISABLED="$HOME/.claude/agents.ccs-disabled"
  local SKILLS_DISABLED="$HOME/.claude/skills.ccs-disabled"

  local RESTORE_AGENTS=""
  local RESTORE_SKILLS=""

  if [[ -d "$AGENTS_DIR" ]]; then
    mv "$AGENTS_DIR" "$AGENTS_DISABLED"
    RESTORE_AGENTS=1
    echo "ccs: disabled agents for this session"
  fi

  if [[ -d "$SKILLS_DIR" ]]; then
    mv "$SKILLS_DIR" "$SKILLS_DISABLED"
    RESTORE_SKILLS=1
    echo "ccs: disabled skills for this session"
  fi

  _cleanup_clean() {
    if [[ -n "${RESTORE_AGENTS:-}" ]] && [[ -d "$AGENTS_DISABLED" ]]; then
      mv "$AGENTS_DISABLED" "$AGENTS_DIR" 2>/dev/null && echo "ccs: restored agents"
    fi
    if [[ -n "${RESTORE_SKILLS:-}" ]] && [[ -d "$SKILLS_DISABLED" ]]; then
      mv "$SKILLS_DISABLED" "$SKILLS_DIR" 2>/dev/null && echo "ccs: restored skills"
    fi
  }

  trap _cleanup_clean EXIT

  local first_arg="${1:-}"

  if [[ "$first_arg" == "--provider" ]]; then
    shift
    cmd_run --provider "$@"
    return
  fi

  if [[ -n "$first_arg" ]]; then
    local path
    path="$(_profile_path "$first_arg")"
    [[ -f "$path" ]] || { echo "error: profile '$first_arg' not found" >&2; exit 1; }
    shift
    claude --settings "$path" "$@"
  else
    [[ -L "$ACTIVE_LINK" ]] || { echo "error: no active profile (run: ccs switch <name>)" >&2; exit 1; }
    claude --settings "$ACTIVE_LINK" "$@"
  fi
}
