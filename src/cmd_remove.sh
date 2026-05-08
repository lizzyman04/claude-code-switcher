cmd_remove() {
  local name="${1:-}"
  [[ -z "$name" ]] && { echo "usage: ccs remove <name>" >&2; exit 1; }
  local path
  path="$(_profile_path "$name")"
  [[ -f "$path" ]] || { echo "error: profile '$name' not found" >&2; exit 1; }
  if [[ -L "$ACTIVE_LINK" ]] && [[ "$(readlink "$ACTIVE_LINK")" == "$path" ]]; then
    rm "$ACTIVE_LINK"
  fi
  rm "$path"
  echo "Removed: $name"
}
