cmd_run() {
  local name="${1:-}"
  [[ -z "$name" ]] && { echo "usage: ccs run <name> [claude args...]" >&2; exit 1; }
  local path
  path="$(_profile_path "$name")"
  [[ -f "$path" ]] || { echo "error: profile '$name' not found" >&2; exit 1; }
  shift
  exec claude --settings "$path" "$@"
}
