cmd_edit() {
  local spec="${1:-}"
  [[ -z "$spec" ]] && { echo "usage: ccs edit <provider>[@<account>]" >&2; exit 1; }
  _resolve_spec_or_die "$spec"
  "${EDITOR:-vi}" "$(_account_path "$SPEC_PROVIDER" "$SPEC_ACCOUNT")"
}
