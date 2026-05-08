cmd_edit() {
  local name="${1:-}"
  [[ -z "$name" ]] && { echo "usage: ccs edit <name>" >&2; exit 1; }
  local path
  path="$(_profile_path "$name")"
  [[ -f "$path" ]] || { echo "error: profile '$name' not found" >&2; exit 1; }
  "${EDITOR:-vi}" "$path"
}
