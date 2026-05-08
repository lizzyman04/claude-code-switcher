cmd_current() {
  local active
  active="$(_active_name)"
  if [[ "$active" == "(none)" ]]; then
    echo "No active profile. Run: ccs switch <name>"
    return
  fi
  echo "Active: $active"
  _require_jq
  jq 'del(.env.ANTHROPIC_AUTH_TOKEN)' "$ACTIVE_LINK"
}
