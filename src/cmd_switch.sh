cmd_switch() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "Available profiles:"
    cmd_list
    echo ""
    echo "Usage: ccs switch <name>"
    return 1
  fi
  local path
  path="$(_profile_path "$name")"
  [[ -f "$path" ]] || { echo "error: profile '$name' not found" >&2; exit 1; }

  local token base_url
  token="$(_read_env_field "$path" ANTHROPIC_AUTH_TOKEN)"
  base_url="$(_read_env_field "$path" ANTHROPIC_BASE_URL)"

  if [[ -n "$base_url" ]]; then
    if [[ -z "$token" || "$token" == '""' ]]; then
      echo "error: profile '$name' has no API key set" >&2
      echo "Set it with: ccs key $name" >&2
      return 1
    fi
  fi

  ln -sf "$path" "$ACTIVE_LINK"
  echo "Switched to $name"
}
