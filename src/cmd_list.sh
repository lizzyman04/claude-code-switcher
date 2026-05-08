cmd_list() {
  _ensure_aliases
  local active
  active="$(_active_name)"
  if [[ ! -d "$PROFILES_DIR" ]] || [[ -z "$(ls -A "$PROFILES_DIR" 2>/dev/null)" ]]; then
    echo "No profiles found. Run: ccs add <name>"
    return
  fi
  for f in "$PROFILES_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    local name
    name="$(basename "$f" .json)"
    if [[ "$name" == "$active" ]]; then
      echo "* $name (active)"
    else
      echo "  $name"
    fi
  done
}
