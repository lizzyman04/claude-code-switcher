_require_jq() {
  if ! command -v jq &>/dev/null; then
    echo "error: jq is required (apt install jq / brew install jq)" >&2
    exit 1
  fi
}

_profile_path() {
  echo "$PROFILES_DIR/$1.json"
}

_active_name() {
  if [[ ! -L "$ACTIVE_LINK" ]]; then
    echo "(none)"
    return
  fi
  basename "$(readlink "$ACTIVE_LINK")" .json
}

_read_env_field() {
  jq -r ".env.$2 // empty" "$1"
}

_ensure_aliases() {
  local shell_config=""
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -f "$rc" ]] && { shell_config="$rc"; break; }
  done
  if [[ -n "$shell_config" ]] && ! grep -q "alias claude=.*claude-profiles/active" "$shell_config" 2>/dev/null; then
    echo "Aliases not configured. Add them? [Y/n]"
    read -r response
    if [[ "$response" =~ ^[Yy]?$ ]]; then
      echo "" >> "$shell_config"
      echo "# ccs aliases" >> "$shell_config"
      echo "alias claude='claude --settings \$HOME/.config/claude-profiles/active'" >> "$shell_config"
      echo "alias deepseek='ccs run deepseek'" >> "$shell_config"
      echo "Done. Run: source $shell_config"
    fi
  fi
}
