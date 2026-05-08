cmd_key() {
  local name="${1:-}"
  [[ -z "$name" ]] && { echo "usage: ccs key <name>" >&2; exit 1; }
  local path
  path="$(_profile_path "$name")"
  [[ -f "$path" ]] || { echo "error: profile '$name' not found" >&2; exit 1; }
  _require_jq
  read -rsp "New API key for '$name': " new_key
  echo
  local tmp
  tmp="$(mktemp)"
  jq --arg k "$new_key" '.env.ANTHROPIC_AUTH_TOKEN = $k' "$path" > "$tmp" && mv "$tmp" "$path"
  echo "Updated API key for $name"
}
